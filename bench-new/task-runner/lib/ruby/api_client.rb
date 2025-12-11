# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module TaskRunner
  class ApiClient
    def initialize(base_url, api_key)
      @base_url = base_url.chomp("/")
      @api_key = api_key
    end

    def claim_task(run_id, provider, instance_type, runner_id)
      post("/runs/#{run_id}/tasks/claim", {
        provider: provider,
        instance_type: instance_type,
        runner_id: runner_id
      })
    end

    def heartbeat(task_id, runner_id, status, message: nil, current_benchmark: nil, progress_pct: nil)
      payload = { runner_id: runner_id, status: status }
      payload[:message] = message if message
      payload[:current_benchmark] = current_benchmark if current_benchmark
      payload[:progress_pct] = progress_pct if progress_pct

      post("/tasks/#{task_id}/heartbeat", payload)
    end

    def complete_task(task_id, runner_id, s3_result_key)
      post("/tasks/#{task_id}/complete", {
        runner_id: runner_id,
        s3_result_key: s3_result_key
      })
    end

    def fail_task(task_id, runner_id, error_type, error_message, s3_error_key, debug_mode)
      post("/tasks/#{task_id}/fail", {
        runner_id: runner_id,
        error_type: error_type,
        error_message: error_message,
        s3_error_key: s3_error_key,
        debug_mode: debug_mode
      })
    end

    private

    def post(path, body)
      uri = URI("#{@base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30

      request = Net::HTTP::Post.new(uri.path)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      response = http.request(request)

      return nil unless response.is_a?(Net::HTTPSuccess)
      return {} if response.body.nil? || response.body.empty?

      JSON.parse(response.body)
    rescue StandardError
      nil
    end

    def put_file(url, file_path)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 120

      request = Net::HTTP::Put.new(uri.request_uri)
      request["Content-Type"] = "application/gzip"
      request.body = File.binread(file_path)

      response = http.request(request)
      response.is_a?(Net::HTTPSuccess)
    rescue StandardError
      false
    end
  end
end
