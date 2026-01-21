require "test_helper"

class TasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @api_key = ENV.fetch('API_KEY', 'dev_api_key_change_in_production')
    @run = Run.create!(ruby_version: "3.4.7", tasks_per_instance_type: 2)
    @task = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
  end

  test "POST /runs/:run_id/tasks/claim assigns a task" do
    post "/runs/#{@run.external_id}/tasks/claim",
      params: { provider: "aws", instance_type: "c8g.medium", runner_id: "i-12345" },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal "assigned", json['status']
    assert json['task'].present?
    assert_equal @task.id, json['task']['id']
    assert json['presigned_urls'].present?

    @task.reload
    assert_equal "claimed", @task.status
    assert_equal "i-12345", @task.runner_id
  end

  test "POST /runs/:run_id/tasks/claim returns wait when tasks are in progress" do
    @task.claim!("other-runner")

    post "/runs/#{@run.external_id}/tasks/claim",
      params: { provider: "aws", instance_type: "c8g.medium", runner_id: "i-12345" },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal "wait", json['status']
    assert_equal 30, json['retry_after_seconds']
  end

  test "POST /runs/:run_id/tasks/claim returns done when all tasks completed" do
    @task.claim!("runner-1")
    @task.complete!("results/1/task_1.tar.gz")

    post "/runs/#{@run.external_id}/tasks/claim",
      params: { provider: "aws", instance_type: "c8g.medium", runner_id: "i-12345" },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal "done", json['status']
  end

  test "POST /runs/:run_id/tasks/claim requires authentication" do
    post "/runs/#{@run.external_id}/tasks/claim",
      params: { provider: "aws", instance_type: "c8g.medium", runner_id: "i-12345" },
      as: :json

    assert_response :unauthorized
  end

  test "POST /runs/:run_id/tasks/claim returns done when run is cancelled" do
    @run.cancel!

    post "/runs/#{@run.external_id}/tasks/claim",
      params: { provider: "aws", instance_type: "c8g.medium", runner_id: "i-12345" },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal "done", json['status']
    assert_equal "Run is not running", json['message']
  end

  test "POST /tasks/:id/heartbeat updates task heartbeat" do
    @task.claim!("runner-123")

    post "/tasks/#{@task.id}/heartbeat",
      params: {
        runner_id: "runner-123",
        status: "running",
        current_benchmark: "optcarrot",
        progress_pct: 50,
        message: "Running benchmark"
      },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :success
    @task.reload

    assert_equal "running", @task.status
    assert_equal "running", @task.heartbeat_status
    assert_equal "optcarrot", @task.current_benchmark
    assert_equal 50, @task.progress_pct
  end

  test "POST /tasks/:id/heartbeat validates runner_id" do
    @task.claim!("runner-123")

    post "/tasks/#{@task.id}/heartbeat",
      params: { runner_id: "wrong-runner", status: "running" },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :forbidden
  end

  test "POST /tasks/:id/complete marks task as completed" do
    @task.claim!("runner-123")

    post "/tasks/#{@task.id}/complete",
      params: { runner_id: "runner-123", s3_result_key: "results/1/task_1.tar.gz" },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :success
    @task.reload

    assert_equal "completed", @task.status
    assert_equal "results/1/task_1.tar.gz", @task.s3_result_key
  end

  test "POST /tasks/:id/complete validates runner_id" do
    @task.claim!("runner-123")

    post "/tasks/#{@task.id}/complete",
      params: { runner_id: "wrong-runner", s3_result_key: "results/1/task_1.tar.gz" },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :forbidden
  end

  test "POST /tasks/:id/fail marks task as failed" do
    @task.claim!("runner-123")

    post "/tasks/#{@task.id}/fail",
      params: {
        runner_id: "runner-123",
        error_type: "benchmark_error",
        error_message: "Benchmark failed",
        s3_error_key: "errors/1/task_1.tar.gz"
      },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :success
    @task.reload

    assert_equal "failed", @task.status
    assert_equal "benchmark_error", @task.error_type
    assert_equal "Benchmark failed", @task.error_message
  end

  test "POST /tasks/:id/fail validates runner_id" do
    @task.claim!("runner-123")

    post "/tasks/#{@task.id}/fail",
      params: {
        runner_id: "wrong-runner",
        error_type: "benchmark_error",
        error_message: "Benchmark failed"
      },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :forbidden
  end
end
