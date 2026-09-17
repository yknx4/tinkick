# frozen_string_literal: true

require_relative "../test_helper"
require "active_record"
require "rails/generators/test_case"
require "generators/tinkick/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  class_attribute :use_transactional_tests, default: false

  tests Tinkick::Generators::InstallGenerator
  destination File.expand_path("../../tmp/install_generator", __dir__)
  setup :prepare_destination

  test "creates a timestamped Rails migration" do
    run_generator

    files = Dir[File.join(destination_root, "db/migrate/*_enable_tin_for_tinkick.rb")]
    assert_equal 1, files.length
    assert_match(/\A\d{14}_enable_tin_for_tinkick\.rb\z/, File.basename(files.first))

    assert_migration "db/migrate/enable_tin_for_tinkick.rb" do |migration|
      assert_match "ActiveRecord::Migration[8.0]", migration
      assert_match 'enable_extension "tin"', migration
      assert_equal ["tin"], migration.scan(/enable_extension "([^"]+)"/).flatten
    end
  end

  test "includes only requested optional extensions" do
    %w[unaccent fuzzystrmatch pg-trgm].each do |flag|
      prepare_destination
      run_generator(["--#{flag}"])

      assert_migration "db/migrate/enable_tin_for_tinkick.rb" do |migration|
        assert_equal ["tin", flag.tr("-", "_")], migration.scan(/enable_extension "([^"]+)"/).flatten
      end
    end
  end

  test "combines optional extension flags and preserves the generated migration" do
    run_generator(["--unaccent", "--fuzzystrmatch", "--pg-trgm"])
    migration_path = Dir[File.join(destination_root, "db/migrate/*.rb")].fetch(0)
    migration = File.read(migration_path)

    assert_equal %w[tin unaccent fuzzystrmatch pg_trgm], migration.scan(/enable_extension "([^"]+)"/).flatten
    run_generator(["--unaccent", "--fuzzystrmatch", "--pg-trgm"])
    assert_equal [migration_path], Dir[File.join(destination_root, "db/migrate/*.rb")]
    assert_equal migration, File.read(migration_path)
  end

  test "retains an existing installation migration when rerun" do
    run_generator
    files = Dir[File.join(destination_root, "db/migrate/*.rb")]

    run_generator

    assert_equal files, Dir[File.join(destination_root, "db/migrate/*.rb")]
  end

  test "does not overwrite an edited installation migration" do
    run_generator
    migration_path = Dir[File.join(destination_root, "db/migrate/*.rb")].fetch(0)
    edited_migration = File.read(migration_path) + "\n# Application-specific setup\n"
    File.write(migration_path, edited_migration)

    capture(:stdout) do
      assert_raises(Rails::Generators::Error) { generator.invoke_all }
    end

    assert_equal edited_migration, File.read(migration_path)
    assert_equal [migration_path], Dir[File.join(destination_root, "db/migrate/*.rb")]
  end

  test "does not allow rollback to disable a shared extension" do
    run_generator
    migration = load_migration

    error = assert_raises(ActiveRecord::IrreversibleMigration) { migration.down }

    assert_match "TIN may be used by other indexes", error.message
  end

  test "executes the generated migration repeatedly against real TIN" do
    run_generator
    migration = load_migration
    ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

    ActiveRecord::Base.with_connection do |connection|
      database = connection.select_value("SELECT current_database()")
      raise "Refusing to run tests against #{database.inspect}; expected tinkick_test" unless database == "tinkick_test"

      assert connection.extension_enabled?("tin"), "tinkick_test must already have TIN enabled"

      capture(:stdout) do
        migration.migrate(:up)
        migration.migrate(:up)
      end

      assert connection.extension_enabled?("tin")
    end
  end

  test "executes optional extension installation repeatedly without disabling them" do
    run_generator(["--unaccent", "--fuzzystrmatch", "--pg-trgm"])
    migration = load_migration
    ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

    ActiveRecord::Base.with_connection do |connection|
      database = connection.select_value("SELECT current_database()")
      raise "Refusing to run tests against #{database.inspect}; expected tinkick_test" unless database == "tinkick_test"

      capture(:stdout) do
        migration.migrate(:up)
        migration.migrate(:up)
      end

      %w[tin unaccent fuzzystrmatch pg_trgm].each do |extension|
        assert connection.extension_enabled?(extension), "#{extension} should remain installed"
      end
      assert_raises(ActiveRecord::IrreversibleMigration) { migration.down }
    end
  end

  private

  def load_migration
    migration_path = Dir[File.join(destination_root, "db/migrate/*_enable_tin_for_tinkick.rb")].fetch(0)
    migration_namespace = Module.new
    migration_namespace.module_eval(File.read(migration_path), migration_path)
    migration_namespace.const_get(:EnableTinForTinkick).new
  end
end
