#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "optparse"

require_relative "worker"

module TaskRunner
  class Main
    def self.run(args = ARGV)
      options = parse_options(args)
      validate_options!(options)

      runner_id = "#{`hostname`.strip}-#{Time.now.to_i}-#{Process.pid}"

      logger = Logger.new(debug_mode: options[:debug_mode])

      logger.info "========================================"
      logger.info "Task Runner Starting"
      logger.info "========================================"
      logger.info "Orchestrator: #{options[:orchestrator_url]}"
      logger.info "Run ID: #{options[:run_id]}"
      logger.info "Provider: #{options[:provider]}"
      logger.info "Instance Type: #{options[:instance_type]}"
      logger.info "Runner ID: #{runner_id}"
      logger.info "Benchmark Mode: #{options[:mock_mode] ? "mock" : "ruby-bench"}"
      logger.info "Debug Mode: #{options[:debug_mode]}"
      logger.info "Ruby: #{RUBY_VERSION}"
      logger.info "========================================"

      worker = Worker.new(
        orchestrator_url: options[:orchestrator_url],
        api_key: options[:api_key],
        run_id: options[:run_id],
        provider: options[:provider],
        instance_type: options[:instance_type],
        runner_id: runner_id,
        mock_mode: options[:mock_mode],
        debug_mode: options[:debug_mode],
        script_dir: options[:script_dir]
      )

      exit_code = worker.run

      logger.info "========================================"
      logger.info "Task Runner Finished"
      logger.info "Exit Code: #{exit_code}"
      logger.info "========================================"

      exit(exit_code)
    end

    def self.parse_options(args)
      options = {
        orchestrator_url: nil,
        api_key: nil,
        run_id: nil,
        provider: nil,
        instance_type: nil,
        mock_mode: false,
        debug_mode: false,
        script_dir: File.expand_path("../..", __dir__)
      }

      OptionParser.new do |opts|
        opts.banner = "Usage: main.rb [OPTIONS]"

        opts.on("--orchestrator-url URL", "Orchestrator base URL (required)") do |v|
          options[:orchestrator_url] = v
        end

        opts.on("--api-key KEY", "API authentication key (required)") do |v|
          options[:api_key] = v
        end

        opts.on("--run-id ID", "Run ID to claim tasks from (required)") do |v|
          options[:run_id] = v
        end

        opts.on("--provider PROVIDER", "Provider name: local, aws, azure (required)") do |v|
          options[:provider] = v
        end

        opts.on("--instance-type TYPE", "Instance type (required)") do |v|
          options[:instance_type] = v
        end

        opts.on("--mock", "Use mock benchmark instead of ruby-bench") do
          options[:mock_mode] = true
        end

        opts.on("--debug", "Don't shutdown on failure") do
          options[:debug_mode] = true
        end

        opts.on("--script-dir DIR", "Script directory (for finding mock benchmark)") do |v|
          options[:script_dir] = v
        end

        opts.on("-h", "--help", "Show this help message") do
          puts opts
          exit(0)
        end
      end.parse!(args)

      options
    end

    def self.validate_options!(options)
      missing = []
      missing << "--orchestrator-url" unless options[:orchestrator_url]
      missing << "--api-key" unless options[:api_key]
      missing << "--run-id" unless options[:run_id]
      missing << "--provider" unless options[:provider]
      missing << "--instance-type" unless options[:instance_type]

      return if missing.empty?

      $stderr.puts "Error: Missing required arguments: #{missing.join(", ")}"
      exit(1)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  TaskRunner::Main.run
end
