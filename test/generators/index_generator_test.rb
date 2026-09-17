# frozen_string_literal: true

require_relative "../test_helper"
require "active_record"
require "rails/generators/test_case"
require "generators/tinkick/index/index_generator"

class IndexGeneratorTest < Rails::Generators::TestCase
  # Declare this locally even when Rails' fixture helpers load after this file.
  # The schema test commits its migrations and removes its table in ensure.
  class_attribute :use_transactional_tests, default: false

  tests Tinkick::Generators::IndexGenerator
  destination File.expand_path("../../tmp/index_generator", __dir__)
  setup :prepare_destination

  test "creates one TIN index per field in a timestamped Rails migration" do
    run_generator ["products", "name", "description"]

    files = Dir[File.join(destination_root, "db/migrate/*.rb")]
    assert_equal 1, files.length
    assert_match(/\A\d{14}_add_tin_indexes_to_products_on_name_and_description\.rb\z/, File.basename(files.first))

    assert_migration "db/migrate/add_tin_indexes_to_products_on_name_and_description.rb" do |migration|
      assert_match "ActiveRecord::Migration[8.0]", migration
      assert_match 'add_index "products", "name", using: :tin, name: "products_name_tin"', migration
      assert_match 'add_index "products", "description", using: :tin, name: "products_description_tin"', migration
    end
  end

  test "requires at least one field" do
    error = assert_raises(Thor::RequiredArgumentMissingError) { generator_class.new(["products"]) }

    assert_match "fields", error.message
    assert_empty Dir[File.join(destination_root, "db/migrate/*.rb")]
  end

  test "rejects invalid table and field identifiers before writing" do
    [["products;DROP TABLE users", "name"], ["public.products", "name"], ["products", "name:string"], ["products", ""]].each do |arguments|
      error = assert_raises(Thor::Error) { generator_class.new(arguments).invoke_all }

      assert_match "plain PostgreSQL identifiers", error.message
      assert_empty Dir[File.join(destination_root, "db/migrate/*.rb")]
    end
  end

  test "rejects duplicate fields" do
    error = assert_raises(Thor::Error) { generator_class.new(["products", "name", "name"]).invoke_all }

    assert_match "unique", error.message
    assert_empty Dir[File.join(destination_root, "db/migrate/*.rb")]
  end

  test "does not duplicate an existing index migration" do
    run_generator ["products", "name", "description"]
    files = Dir[File.join(destination_root, "db/migrate/*.rb")]

    run_generator ["products", "name", "description"]

    assert_equal files, Dir[File.join(destination_root, "db/migrate/*.rb")]
  end

  test "does not overwrite an edited index migration" do
    run_generator ["products", "name"]
    migration_path = Dir[File.join(destination_root, "db/migrate/*.rb")].fetch(0)
    edited_migration = File.read(migration_path) + "\n# Application-specific setup\n"
    File.write(migration_path, edited_migration)

    capture(:stdout) do
      assert_raises(Rails::Generators::Error) { generator(["products", "name"]).invoke_all }
    end

    assert_equal edited_migration, File.read(migration_path)
    assert_equal [migration_path], Dir[File.join(destination_root, "db/migrate/*.rb")]
  end

  test "keeps migration filenames within the filesystem limit for many long fields" do
    run_generator ["products", *(1..4).map { |number| "field_#{number}_#{"x" * 50}" }]

    migration_path = Dir[File.join(destination_root, "db/migrate/*.rb")].fetch(0)
    assert_operator File.basename(migration_path).bytesize, :<=, 255
    assert_equal 4, File.read(migration_path).scan("add_index").length
    assert_kind_of ActiveRecord::Migration, load_migration
  end

  test "generates a reversible migration for dotted JSONB text paths without a database connection" do
    run_generator ["products", "metadata.title", "metadata.details.title"]

    files = Dir[File.join(destination_root, "db/migrate/*.rb")]
    assert_equal 1, files.length
    assert_operator File.basename(files.first).bytesize, :<=, 255
    assert_kind_of ActiveRecord::Migration, load_migration

    contents = File.read(files.first)
    run_generator ["products", "metadata.title", "metadata.details.title"]
    assert_equal files, Dir[File.join(destination_root, "db/migrate/*.rb")]
    assert_equal contents, File.read(files.first)
  end

  test "rejects empty and null JSON path components before writing" do
    ["metadata.", "metadata..title", "metadata.\0title"].each do |field|
      assert_raises(Thor::Error) { generator_class.new(["products", field]).invoke_all }
      assert_empty Dir[File.join(destination_root, "db/migrate/*.rb")]
    end
  end

  test "indexes JSONB text expressions with safely quoted paths and reverses the migration" do
    table_name = "tinkick_index_generator_jsonb"
    quoted_key = "quoted'key\"); DROP TABLE ignored; --"
    fields = ["metadata.title", "metadata.details.title", "metadata.#{quoted_key}", "metadata_title"]
    run_generator [table_name, *fields]
    migration = load_migration
    ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

    ActiveRecord::Base.with_connection do |connection|
      database = connection.select_value("SELECT current_database()")
      raise "Refusing to run tests against #{database.inspect}; expected tinkick_test" unless database == "tinkick_test"

      assert connection.extension_enabled?("tin")
      assert_equal 0, connection.open_transactions
      schema_migration = Class.new(ActiveRecord::Migration[8.0]) do
        define_method(:change) do
          create_table table_name do |table|
            table.jsonb :metadata
            table.text :metadata_title
          end
        end
      end.new
      table_created = false

      begin
        capture(:stdout) do
          schema_migration.migrate(:up)
          table_created = true
          migration.migrate(:up)
        end
        indexes = connection.indexes(table_name)
        assert_equal 4, indexes.length
        assert_equal 4, indexes.map(&:name).uniq.length
        assert indexes.all? { |index| index.name.bytesize <= 63 }
        assert_equal ["tin"], indexes.map { |index| index.using.to_s }.uniq

        model = Class.new(ActiveRecord::Base) { self.table_name = table_name }
        first = model.create!(metadata: { title: "Moria mithril", details: { title: "Gondolin refuge" }, quoted_key => "Rivendell refuge" })
        second = model.create!(metadata: { title: "Gondolin history", details: { title: nil } })
        model.create!(metadata: {})
        model.create!(metadata: nil)

        assert_equal [first.id], model.where("(metadata ->> 'title') ==> ?", "mithril").ids
        assert_equal [first.id], model.where("(metadata -> 'details' ->> 'title') ==> ?", "gondolin").ids
        assert_equal [second.id], model.where("(metadata ->> 'title') ==> ?", "gondolin").ids
        assert_equal [first.id], model.where("(metadata ->> #{connection.quote(quoted_key)}) ==> ?", "rivendell").ids
        model.where(id: first.id).update_all(metadata: { details: { title: "Lothlorien refuge" } })
        assert_empty model.where("(metadata -> 'details' ->> 'title') ==> ?", "gondolin")
        assert_equal [first.id], model.where("(metadata -> 'details' ->> 'title') ==> ?", "lothlorien").ids

        capture(:stdout) { migration.migrate(:down) }
        assert_empty connection.indexes(table_name)
        assert_equal 4, model.count
      ensure
        capture(:stdout) { schema_migration.migrate(:down) } if table_created
      end
      refute connection.table_exists?(table_name)
    end
  end

  test "validates JSONB root column types before adding expression indexes" do
    table_name = "tinkick_index_generator_invalid_jsonb"
    ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

    ActiveRecord::Base.with_connection do |connection|
      database = connection.select_value("SELECT current_database()")
      raise "Refusing to run tests against #{database.inspect}; expected tinkick_test" unless database == "tinkick_test"

      assert_equal 0, connection.open_transactions
      schema_migration = Class.new(ActiveRecord::Migration[8.0]) do
        define_method(:change) do
          create_table table_name do |table|
            table.text :description
            table.jsonb :items, array: true
          end
        end
      end.new
      table_created = false

      begin
        capture(:stdout) do
          schema_migration.migrate(:up)
          table_created = true
        end
        ["description.title", "missing.title", "items.title"].each do |field|
          prepare_destination
          run_generator [table_name, field]
          migration = load_migration
          error = nil
          capture(:stdout) { error = assert_raises(ArgumentError) { migration.migrate(:up) } }
          assert_includes error.message, "JSONB"
          assert_includes error.message, field.split(".").first
          assert_empty connection.indexes(table_name)
        end
      ensure
        capture(:stdout) { schema_migration.migrate(:down) } if table_created
      end
    end
  end

  test "creates searchable real TIN indexes with bounded names and reverses them" do
    table_name = "tinkick_index_generator_products"
    fields = ["description_#{"a" * 51}", "description_#{"a" * 50}b"]
    run_generator [table_name, *fields]
    migration = load_migration
    ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

    ActiveRecord::Base.with_connection do |connection|
      database = connection.select_value("SELECT current_database()")
      raise "Refusing to run tests against #{database.inspect}; expected tinkick_test" unless database == "tinkick_test"

      assert connection.extension_enabled?("tin"), "tinkick_test must already have TIN enabled"
      assert_equal 0, connection.open_transactions, "schema generator tests require committed migrations outside fixture transactions"

      schema_migration = Class.new(ActiveRecord::Migration[8.0]) do
        define_method(:change) do
          create_table table_name do |table|
            fields.each { |field| table.text field }
          end
        end
      end.new
      table_created = false

      begin
        capture(:stdout) do
          schema_migration.migrate(:up)
          table_created = true
          migration.migrate(:up)
        end

        indexes = connection.indexes(table_name)
        assert_equal fields.sort, indexes.flat_map(&:columns).sort
        assert_equal ["tin"], indexes.map { |index| index.using.to_s }.uniq
        assert_equal 2, indexes.map(&:name).uniq.length
        assert indexes.all? { |index| index.name.bytesize == 63 }
        assert indexes.all? { |index| index.name.end_with?("_tin") }

        model = Class.new(ActiveRecord::Base) { self.table_name = table_name }
        record = model.create!(fields[0] => "apple orchard", fields[1] => "fresh fruit")
        fields.zip(["orchard", "fresh"]).each do |field, term|
          matches = model.where("#{connection.quote_column_name(field)} ==> ?", term).pluck(:id)
          assert_equal [record.id], matches
        end

        capture(:stdout) { migration.migrate(:down) }

        assert_empty connection.indexes(table_name)
        assert_equal 1, model.count
      ensure
        capture(:stdout) { schema_migration.migrate(:down) } if table_created
      end
      refute connection.table_exists?(table_name)
    end
  end

  private

  def load_migration
    migration_path = Dir[File.join(destination_root, "db/migrate/*.rb")].fetch(0)
    migration_namespace = Module.new
    migration_namespace.module_eval(File.read(migration_path), migration_path)
    migration_namespace.constants.fetch(0).then { |name| migration_namespace.const_get(name).new }
  end
end
