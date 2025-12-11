# frozen_string_literal: true

require_relative "test_helper"

class ApiClientTest < Minitest::Test
  def setup
    @client = TaskRunner::ApiClient.new("http://orchestrator:3000", "test-api-key")
  end

  def test_claim_task_sends_correct_request
    stub_request(:post, "http://orchestrator:3000/runs/12345/tasks/claim")
      .with(
        headers: {
          "Authorization" => "Bearer test-api-key",
          "Content-Type" => "application/json"
        },
        body: {
          provider: "aws",
          instance_type: "c8g.medium",
          runner_id: "runner-123"
        }.to_json
      )
      .to_return(
        status: 200,
        body: {
          status: "assigned",
          task: { id: 42, provider: "aws", instance_type: "c8g.medium" }
        }.to_json
      )

    response = @client.claim_task(12345, "aws", "c8g.medium", "runner-123")

    assert_equal "assigned", response["status"]
    assert_equal 42, response["task"]["id"]
  end

  def test_claim_task_returns_nil_on_failure
    stub_request(:post, "http://orchestrator:3000/runs/12345/tasks/claim")
      .to_return(status: 500)

    response = @client.claim_task(12345, "aws", "c8g.medium", "runner-123")

    assert_nil response
  end

  def test_claim_task_returns_nil_on_network_error
    stub_request(:post, "http://orchestrator:3000/runs/12345/tasks/claim")
      .to_timeout

    response = @client.claim_task(12345, "aws", "c8g.medium", "runner-123")

    assert_nil response
  end

  def test_heartbeat_sends_correct_request
    stub_request(:post, "http://orchestrator:3000/tasks/42/heartbeat")
      .with(
        headers: { "Authorization" => "Bearer test-api-key" },
        body: hash_including(
          "runner_id" => "runner-123",
          "status" => "running",
          "message" => "Running benchmark"
        )
      )
      .to_return(status: 200, body: "")

    response = @client.heartbeat(42, "runner-123", "running", message: "Running benchmark")

    assert_equal({}, response)
  end

  def test_heartbeat_with_progress
    stub_request(:post, "http://orchestrator:3000/tasks/42/heartbeat")
      .with(
        body: hash_including(
          "current_benchmark" => "optcarrot",
          "progress_pct" => 50
        )
      )
      .to_return(status: 200, body: "")

    response = @client.heartbeat(
      42, "runner-123", "running",
      current_benchmark: "optcarrot",
      progress_pct: 50
    )

    assert_equal({}, response)
  end

  def test_complete_task_sends_correct_request
    stub_request(:post, "http://orchestrator:3000/tasks/42/complete")
      .with(
        body: {
          runner_id: "runner-123",
          s3_result_key: "results/42/result.tar.gz"
        }.to_json
      )
      .to_return(status: 200, body: "")

    response = @client.complete_task(42, "runner-123", "results/42/result.tar.gz")

    assert_equal({}, response)
  end

  def test_fail_task_sends_correct_request
    stub_request(:post, "http://orchestrator:3000/tasks/42/fail")
      .with(
        body: {
          runner_id: "runner-123",
          error_type: "benchmark_crash",
          error_message: "Segmentation fault",
          s3_error_key: "results/42/error.tar.gz",
          debug_mode: false
        }.to_json
      )
      .to_return(status: 200, body: "")

    response = @client.fail_task(
      42, "runner-123", "benchmark_crash",
      "Segmentation fault", "results/42/error.tar.gz", false
    )

    assert_equal({}, response)
  end
end
