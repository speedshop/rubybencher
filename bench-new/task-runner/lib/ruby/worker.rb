#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "api_client"
require_relative "benchmark_runner"
require_relative "heartbeat"
require_relative "packager"
require_relative "logger"

module TaskRunner
  class Worker
    def initialize(orchestrator_url:, api_key:, run_id:, provider:, instance_type:, runner_id:, mock_mode: false, debug_mode: false, no_exit: false, script_dir: nil, log_file: nil)
      @orchestrator_url = orchestrator_url
      @api_key = api_key
      @run_id = run_id
      @provider = provider
      @instance_type = instance_type
      @runner_id = runner_id
      @mock_mode = mock_mode
      @debug_mode = debug_mode
      @no_exit = no_exit
      @script_dir = script_dir || File.expand_path("../..", __dir__)
      @log_file = log_file
      @api = ApiClient.new(orchestrator_url, api_key)
      @logger = Logger.new(debug_mode: debug_mode)
    end

    def run
      @logger.info "Worker starting (runner_id: #{@runner_id}, run_id: #{@run_id})"

      loop do
        @logger.info "Claiming task..."

        claim_response = claim_task_with_retry
        return 1 unless claim_response

        case claim_response["status"]
        when "assigned"
          process_task(claim_response)
        when "wait"
          retry_after = claim_response["retry_after_seconds"] || 30
          @logger.info "Waiting #{retry_after} seconds for tasks..."
          sleep(retry_after)
        when "done"
          if @no_exit
            @logger.info "Received 'done' signal, but no-exit mode enabled. Waiting..."
            sleep(30)
          else
            @logger.info "Received 'done' signal, shutting down"
            return 0
          end
        when nil, ""
          if @no_exit
            @logger.info "Received empty status, but no-exit mode enabled. Waiting..."
            sleep(30)
          else
            @logger.info "Received empty status, shutting down"
            return 0
          end
        else
          if claim_response["error"]
            @logger.info "Received error: #{claim_response["error"]} - shutting down"
            return 0
          end
          @logger.error "Received unknown claim status: #{claim_response["status"]}"
          sleep(30)
        end
      end
    end

    private

    def claim_task_with_retry
      max_attempts = 3
      backoff = 5

      max_attempts.times do |attempt|
        response = @api.claim_task(@run_id, @provider, @instance_type, @runner_id)
        return response if response

        @logger.warn "API call failed (attempt #{attempt + 1}/#{max_attempts}), retrying in #{backoff} seconds..."
        sleep(backoff)
        backoff = [backoff * 2, 60].min
      end

      @logger.error "Failed to claim task after #{max_attempts} attempts"
      nil
    end

    def process_task(claim_response)
      task = claim_response["task"]
      presigned_urls = claim_response["presigned_urls"]

      task_id = task["id"]
      ruby_version = task["ruby_version"]
      run_number = task["run_number"]
      provider = task["provider"]
      instance_type = task["instance_type"]

      result_url = presigned_urls["result_upload_url"]
      error_url = presigned_urls["error_upload_url"]
      result_key = presigned_urls["result_key"]
      error_key = presigned_urls["error_key"]

      @logger.info "Processing task #{task_id} (Ruby #{ruby_version}, run #{run_number})"

      work_dir = "/tmp/task-runner-#{task_id}"
      FileUtils.mkdir_p(work_dir)

      start_time = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

      heartbeat = Heartbeat.new(
        api: @api,
        task_id: task_id,
        runner_id: @runner_id
      )
      heartbeat.start

      begin
        heartbeat.update(status: "running", message: "Starting benchmark")

        benchmark = BenchmarkRunner.new(
          work_dir: work_dir,
          ruby_version: ruby_version,
          mock_mode: @mock_mode,
          script_dir: @script_dir,
          logger: @logger
        ) { |benchmark_name, progress, message| heartbeat.update(status: "running", current_benchmark: benchmark_name, progress_pct: progress, message: message) }

        unless benchmark.run
          end_time = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
          handle_task_failure(
            task_id: task_id,
            work_dir: work_dir,
            provider: provider,
            instance_type: instance_type,
            ruby_version: ruby_version,
            run_number: run_number,
            start_time: start_time,
            end_time: end_time,
            error_type: "benchmark_failed",
            error_message: "Benchmark execution failed",
            error_url: error_url,
            error_key: error_key,
            heartbeat: heartbeat
          )
          return false
        end

        end_time = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

        heartbeat.update(status: "uploading", message: "Uploading results")

        result_tarball = Packager.package_result(
          work_dir: work_dir,
          task_id: task_id,
          provider: provider,
          instance_type: instance_type,
          ruby_version: ruby_version,
          run_number: run_number,
          start_time: start_time,
          end_time: end_time,
          runner_id: @runner_id,
          log_file: @log_file
        )

        unless Packager.upload(result_tarball, result_url, logger: @logger)
          handle_task_failure(
            task_id: task_id,
            work_dir: work_dir,
            provider: provider,
            instance_type: instance_type,
            ruby_version: ruby_version,
            run_number: run_number,
            start_time: start_time,
            end_time: end_time,
            error_type: "upload_failed",
            error_message: "Failed to upload results",
            error_url: error_url,
            error_key: error_key,
            heartbeat: heartbeat
          )
          return false
        end

        heartbeat.update(status: "finished", message: "Complete")
        @api.complete_task(task_id, @runner_id, result_key)

        @logger.info "Completed task #{task_id} successfully"
      ensure
        heartbeat.stop
        FileUtils.rm_rf(work_dir) unless @debug_mode
      end

      true
    end

    def handle_task_failure(task_id:, work_dir:, provider:, instance_type:, ruby_version:, run_number:, start_time:, end_time:, error_type:, error_message:, error_url:, error_key:, heartbeat:)
      @logger.error "Task #{task_id} failed: #{error_message}"

      heartbeat.update(status: "error", message: error_message)

      error_tarball = Packager.package_error(
        work_dir: work_dir,
        task_id: task_id,
        provider: provider,
        instance_type: instance_type,
        ruby_version: ruby_version,
        run_number: run_number,
        start_time: start_time,
        end_time: end_time,
        error_message: error_message,
        runner_id: @runner_id,
        log_file: @log_file
      )

      Packager.upload(error_tarball, error_url, logger: @logger)

      @api.fail_task(task_id, @runner_id, error_type, error_message, error_key, @debug_mode)

      if @debug_mode
        @logger.warn "Debug mode enabled, keeping work directory: #{work_dir}"
      end
    end
  end
end
