# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "benchmark_runner"

class BenchmarkRunnerTest < Minitest::Test
  def setup
    @script_dir = File.expand_path("..", __dir__)
    @logger = TaskRunner::Logger.new(debug_mode: false)
  end

  def test_mock_mode_creates_output_file
    ENV["MOCK_ALWAYS_SUCCEED"] = "1"

    Dir.mktmpdir do |work_dir|
      runner = TaskRunner::BenchmarkRunner.new(
        work_dir: work_dir,
        ruby_version: "3.4.0",
        mock_mode: true,
        script_dir: @script_dir,
        logger: @logger
      )

      result = runner.run

      assert result, "Expected benchmark to succeed"
      assert File.exist?(File.join(work_dir, "output.txt")), "Expected output.txt to be created"
    end
  ensure
    ENV.delete("MOCK_ALWAYS_SUCCEED")
  end

  def test_mock_mode_reports_progress
    ENV["MOCK_ALWAYS_SUCCEED"] = "1"
    progress_reports = []

    Dir.mktmpdir do |work_dir|
      runner = TaskRunner::BenchmarkRunner.new(
        work_dir: work_dir,
        ruby_version: "3.4.0",
        mock_mode: true,
        script_dir: @script_dir,
        logger: @logger
      ) do |benchmark_name, progress, message|
        progress_reports << { name: benchmark_name, progress: progress, message: message }
      end

      runner.run

      assert progress_reports.any?, "Expected progress to be reported"
      assert progress_reports.any? { |r| r[:progress] == 0 }, "Expected start progress"
      assert progress_reports.any? { |r| r[:progress] == 100 }, "Expected completion progress"
    end
  ensure
    ENV.delete("MOCK_ALWAYS_SUCCEED")
  end

  def test_mock_mode_output_contains_ruby_version
    ENV["MOCK_ALWAYS_SUCCEED"] = "1"

    Dir.mktmpdir do |work_dir|
      runner = TaskRunner::BenchmarkRunner.new(
        work_dir: work_dir,
        ruby_version: "3.4.0",
        mock_mode: true,
        script_dir: @script_dir,
        logger: @logger
      )

      runner.run

      output = File.read(File.join(work_dir, "output.txt"))
      assert output.include?("Ruby Version"), "Expected output to include Ruby version"
    end
  ensure
    ENV.delete("MOCK_ALWAYS_SUCCEED")
  end

  def test_mock_mode_returns_false_on_failure
    # Force failure by using a non-existent script directory
    Dir.mktmpdir do |work_dir|
      runner = TaskRunner::BenchmarkRunner.new(
        work_dir: work_dir,
        ruby_version: "3.4.0",
        mock_mode: true,
        script_dir: "/nonexistent/path",
        logger: @logger
      )

      result = runner.run

      assert_equal false, result
    end
  end

  def test_initializer_accepts_all_parameters
    Dir.mktmpdir do |work_dir|
      runner = TaskRunner::BenchmarkRunner.new(
        work_dir: work_dir,
        ruby_version: "3.4.0",
        mock_mode: true,
        script_dir: @script_dir,
        logger: @logger
      ) { |_name, _progress, _message| }

      assert_instance_of TaskRunner::BenchmarkRunner, runner
    end
  end
end
