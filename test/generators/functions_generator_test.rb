# frozen_string_literal: true

require_relative "../test_helper"
require "active_record"
require "rails/generators/test_case"
require "generators/tinkick/functions/functions_generator"

class FunctionsGeneratorTest < Rails::Generators::TestCase
  class_attribute :use_transactional_tests, default: false

  tests Tinkick::Generators::FunctionsGenerator
  destination File.expand_path("../../tmp/functions_generator", __dir__)
  setup :prepare_destination

  test "creates a standalone optional compatibility migration" do
    run_generator

    files = Dir[File.join(destination_root, "db/migrate/*_install_tinkick_functions.rb")]
    assert_equal 1, files.length
    assert_match(/\A\d{14}_install_tinkick_functions\.rb\z/, File.basename(files.first))
    assert_migration "db/migrate/install_tinkick_functions.rb" do |migration|
      assert_match "ActiveRecord::Migration[8.0]", migration
      assert_match "tinkick.osa_distance", migration
      assert_match "tinkick.edit_distance", migration
      refute_match "enable_extension", migration
    end
  end

  test "upgrade creates a separate migration without rewriting the original" do
    run_generator
    original = Dir[File.join(destination_root, "db/migrate/*_install_tinkick_functions.rb")].fetch(0)
    original_contents = File.read(original)

    run_generator ["--upgrade"]

    files = Dir[File.join(destination_root, "db/migrate/*_add_tinkick_edit_distance.rb")]
    assert_equal 1, files.length
    assert_equal original_contents, File.read(original)
    assert_migration "db/migrate/add_tinkick_edit_distance.rb" do |migration|
      assert_match "class AddTinkickEditDistance < ActiveRecord::Migration[8.0]", migration
      assert_match "tinkick.edit_distance", migration
      refute_match "tinkick.osa_distance", migration
      refute_match "require", migration
    end
    contents = File.read(files.fetch(0))
    run_generator ["--upgrade"]
    assert_equal files, Dir[File.join(destination_root, "db/migrate/*_add_tinkick_edit_distance.rb")]
    assert_equal contents, File.read(files.fetch(0))
  end

  test "retains an existing migration when rerun" do
    run_generator
    files = Dir[File.join(destination_root, "db/migrate/*.rb")]
    contents = File.read(files.fetch(0))

    run_generator

    assert_equal files, Dir[File.join(destination_root, "db/migrate/*.rb")]
    assert_equal contents, File.read(files.fetch(0))
  end

  test "does not overwrite application changes" do
    run_generator
    path = Dir[File.join(destination_root, "db/migrate/*.rb")].fetch(0)
    contents = File.read(path) + "\n# Application-specific setup\n"
    File.write(path, contents)

    capture(:stdout) do
      assert_raises(Rails::Generators::Error) { generator.invoke_all }
    end

    assert_equal contents, File.read(path)
  end

  test "installs the generated function repeatedly through real PostgreSQL" do
    run_generator
    path = Dir[File.join(destination_root, "db/migrate/*.rb")].fetch(0)
    namespace = Module.new
    namespace.module_eval(File.read(path), path)
    migration = namespace.const_get(:InstallTinkickFunctions).new
    ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

    ActiveRecord::Base.with_connection do |connection|
      raise "Expected tinkick_test" unless connection.select_value("SELECT current_database()") == "tinkick_test"

      capture(:stdout) do
        migration.migrate(:up)
        migration.migrate(:up)
      end

      assert_equal 1, connection.select_value("SELECT tinkick.osa_distance('apple', 'aplpe', 1)")
      assert_equal 1, connection.select_value("SELECT tinkick.edit_distance('apple', 'aplpe', 2, true)")
      assert_equal 2, connection.select_value("SELECT tinkick.edit_distance('apple', 'aplpe', 2, false)")
    end
  end
end
