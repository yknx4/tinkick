# frozen_string_literal: true

require_relative "test_helper"

class TinkickTest < Minitest::Test
  def test_loading_does_not_open_a_database_connection
    output, status = Open3.capture2e(
      RbConfig.ruby, "-Ilib", "-e",
      'require "active_record"; require "tinkick"; abort "Unexpected connection" if ActiveRecord::Base.connected?',
    )

    assert_predicate(status, :success?, output)
  end

  def test_loading_before_and_after_rails_initialization
    [true, false].each do |load_first|
      script = <<~RUBY
        ENV["DATABASE_URL"] = "postgresql://localhost/tinkick_boot_test"
        require "tinkick" if #{load_first}
        require "rails"
        require "active_record/railtie"

        class TestApplication < Rails::Application
          config.eager_load = false
          config.secret_key_base = "tinkick-test-only"
          config.logger = Logger.new(File::NULL)
        end

        TestApplication.initialize!
        require "tinkick"
        abort "Unexpected connection" if ActiveRecord::Base.connected?
      RUBY

      output, status = Open3.capture2e({ "RAILS_ENV" => "test" }, RbConfig.ruby, "-Ilib", "-e", script)

      assert_predicate(status, :success?, output)
    end
  end
end
