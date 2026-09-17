# frozen_string_literal: true

require "rake/testtask"
require_relative "lib/tinkick/version"

Rake::TestTask.new do |test|
  test.libs << "test"
  test.pattern = "test/**/*_test.rb"
  test.options = "--fail-fast"
  test.ruby_opts << "-r./test/test_helper"
end

desc "Run the full suite with at least 90% line coverage of lib/"
task :coverage do
  sh({ "COVERAGE" => "1" }, "bundle", "exec", "rake", "test")
end

namespace :rbs do
  desc "Format RBS signatures"
  task :format do
    require "rbs"
    require "stringio"

    Dir["sig/**/*.rbs"].sort.each do |path|
      source = File.read(path)
      _buffer, directives, declarations = RBS::Parser.parse_signature(source)
      output = StringIO.new
      RBS::Writer.new(out: output).write(directives + declarations)
      File.write(path, output.string) unless source == output.string
    end
  end

  desc "Validate RBS signatures"
  task :quality do
    sh "bundle", "exec", "rbs", "-I", "sig", "validate"
  end
end

desc "Type check the library"
task :steep do
  sh "bundle", "exec", "steep", "check"
end

desc "Check Ruby style"
task :rubocop do
  sh "bundle", "exec", "rubocop"
end

desc "Build the gem in pkg/"
task :build do
  mkdir_p "pkg"
  sh "gem", "build", "tinkick.gemspec", "--output", "pkg/tinkick-#{Tinkick::VERSION}.gem"
end

task default: [:coverage, :rubocop, "rbs:quality", :steep]
