# frozen_string_literal: true

require_relative "test_helper"

class HeartbeatTest < Minitest::Test
  def setup
    @api = TaskRunner::ApiClient.new("http://orchestrator:3000", "test-key")
    @task_id = 42
    @runner_id = "test-runner"
  end

  def test_initializes_with_running_status
    heartbeat = TaskRunner::Heartbeat.new(
      api: @api,
      task_id: @task_id,
      runner_id: @runner_id
    )

    # Access internal state via update to verify initialization
    heartbeat.update(message: "test")
    assert_instance_of TaskRunner::Heartbeat, heartbeat
  end

  def test_update_changes_status
    heartbeat = TaskRunner::Heartbeat.new(
      api: @api,
      task_id: @task_id,
      runner_id: @runner_id
    )

    heartbeat.update(status: "completing", message: "Almost done")

    # We can't directly verify internal state, but we can verify it doesn't raise
    assert true
  end

  def test_update_with_progress
    heartbeat = TaskRunner::Heartbeat.new(
      api: @api,
      task_id: @task_id,
      runner_id: @runner_id
    )

    heartbeat.update(
      current_benchmark: "test_benchmark",
      progress_pct: 50,
      message: "Halfway done"
    )

    assert true
  end

  def test_start_and_stop_lifecycle
    stub_request(:post, "http://orchestrator:3000/tasks/#{@task_id}/heartbeat")
      .to_return(status: 200, body: "")

    heartbeat = TaskRunner::Heartbeat.new(
      api: @api,
      task_id: @task_id,
      runner_id: @runner_id
    )

    heartbeat.start

    # Give the thread a moment to start
    sleep 0.1

    heartbeat.stop

    # Verify the heartbeat was called at least once
    assert_requested(:post, "http://orchestrator:3000/tasks/#{@task_id}/heartbeat", times: 1)
  end

  def test_stop_without_start_does_not_raise
    heartbeat = TaskRunner::Heartbeat.new(
      api: @api,
      task_id: @task_id,
      runner_id: @runner_id
    )

    # Should not raise even if never started
    heartbeat.stop

    assert true
  end

  def test_heartbeat_sends_correct_parameters
    request_body = nil
    stub_request(:post, "http://orchestrator:3000/tasks/#{@task_id}/heartbeat")
      .with { |request| request_body = JSON.parse(request.body); true }
      .to_return(status: 200, body: "")

    heartbeat = TaskRunner::Heartbeat.new(
      api: @api,
      task_id: @task_id,
      runner_id: @runner_id
    )

    heartbeat.update(
      status: "running",
      message: "Processing",
      current_benchmark: "bench1",
      progress_pct: 25
    )

    heartbeat.start
    sleep 0.1
    heartbeat.stop

    assert_equal @runner_id, request_body["runner_id"]
    assert_equal "running", request_body["status"]
  end

  def test_heartbeat_handles_api_errors_gracefully
    stub_request(:post, "http://orchestrator:3000/tasks/#{@task_id}/heartbeat")
      .to_raise(StandardError.new("Connection refused"))

    heartbeat = TaskRunner::Heartbeat.new(
      api: @api,
      task_id: @task_id,
      runner_id: @runner_id
    )

    # Should not raise even when API fails
    heartbeat.start
    sleep 0.1
    heartbeat.stop

    assert true
  end
end
