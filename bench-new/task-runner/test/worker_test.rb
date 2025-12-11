# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class WorkerTest < Minitest::Test
  def setup
    @script_dir = File.expand_path("..", __dir__)
    @run_id = "12345"
  end

  def test_worker_exits_on_done_status
    stub_request(:post, "http://orchestrator:3000/runs/#{@run_id}/tasks/claim")
      .to_return(
        status: 200,
        body: { status: "done" }.to_json
      )

    worker = TaskRunner::Worker.new(
      orchestrator_url: "http://orchestrator:3000",
      api_key: "test-key",
      run_id: @run_id,
      provider: "local",
      instance_type: "local-docker",
      runner_id: "test-runner",
      mock_mode: true,
      script_dir: @script_dir
    )

    exit_code = worker.run

    assert_equal 0, exit_code
  end

  def test_worker_exits_on_empty_status
    stub_request(:post, "http://orchestrator:3000/runs/#{@run_id}/tasks/claim")
      .to_return(
        status: 200,
        body: { status: nil }.to_json
      )

    worker = TaskRunner::Worker.new(
      orchestrator_url: "http://orchestrator:3000",
      api_key: "test-key",
      run_id: @run_id,
      provider: "local",
      instance_type: "local-docker",
      runner_id: "test-runner",
      mock_mode: true,
      script_dir: @script_dir
    )

    exit_code = worker.run

    assert_equal 0, exit_code
  end

  def test_worker_exits_on_error_response
    stub_request(:post, "http://orchestrator:3000/runs/#{@run_id}/tasks/claim")
      .to_return(
        status: 200,
        body: { error: "Run not found" }.to_json
      )

    worker = TaskRunner::Worker.new(
      orchestrator_url: "http://orchestrator:3000",
      api_key: "test-key",
      run_id: @run_id,
      provider: "local",
      instance_type: "local-docker",
      runner_id: "test-runner",
      mock_mode: true,
      script_dir: @script_dir
    )

    exit_code = worker.run

    assert_equal 0, exit_code
  end

  def test_worker_processes_assigned_task
    claim_response = {
      status: "assigned",
      task: {
        id: 42,
        provider: "local",
        instance_type: "local-docker",
        ruby_version: "3.4.0",
        run_number: 1
      },
      presigned_urls: {
        result_upload_url: "/tmp/test-results/result.tar.gz",
        error_upload_url: "/tmp/test-results/error.tar.gz",
        result_key: "results/42/result.tar.gz",
        error_key: "results/42/error.tar.gz"
      }
    }

    call_count = 0
    stub_request(:post, "http://orchestrator:3000/runs/#{@run_id}/tasks/claim")
      .to_return do
        call_count += 1
        if call_count == 1
          { status: 200, body: claim_response.to_json }
        else
          { status: 200, body: { status: "done" }.to_json }
        end
      end

    stub_request(:post, "http://orchestrator:3000/tasks/42/heartbeat")
      .to_return(status: 200, body: "")

    stub_request(:post, "http://orchestrator:3000/tasks/42/complete")
      .to_return(status: 200, body: "")

    FileUtils.mkdir_p("/tmp/test-results")

    worker = TaskRunner::Worker.new(
      orchestrator_url: "http://orchestrator:3000",
      api_key: "test-key",
      run_id: @run_id,
      provider: "local",
      instance_type: "local-docker",
      runner_id: "test-runner",
      mock_mode: true,
      script_dir: @script_dir
    )

    exit_code = worker.run

    assert_equal 0, exit_code
    assert_requested(:post, "http://orchestrator:3000/tasks/42/complete")
  ensure
    FileUtils.rm_rf("/tmp/test-results")
  end

  def test_worker_retries_on_wait_status
    call_count = 0
    stub_request(:post, "http://orchestrator:3000/runs/#{@run_id}/tasks/claim")
      .to_return do
        call_count += 1
        if call_count == 1
          { status: 200, body: { status: "wait", retry_after_seconds: 0 }.to_json }
        else
          { status: 200, body: { status: "done" }.to_json }
        end
      end

    worker = TaskRunner::Worker.new(
      orchestrator_url: "http://orchestrator:3000",
      api_key: "test-key",
      run_id: @run_id,
      provider: "local",
      instance_type: "local-docker",
      runner_id: "test-runner",
      mock_mode: true,
      script_dir: @script_dir
    )

    exit_code = worker.run

    assert_equal 0, exit_code
    assert_equal 2, call_count
  end
end
