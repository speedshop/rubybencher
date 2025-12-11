require "test_helper"

class TaskTest < ActiveSupport::TestCase
  def setup
    @run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
  end

  test "creates task with default pending status" do
    task = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)

    assert_equal "pending", task.status
    assert task.claimable?
  end

  test "claim! updates task status and timestamps" do
    task = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-123")

    assert_equal "claimed", task.status
    assert_equal "runner-123", task.runner_id
    assert task.claimed_at.present?
    assert task.heartbeat_at.present?
  end

  test "update_heartbeat! updates status and timestamps" do
    task = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-123")

    task.update_heartbeat!(
      heartbeat_status: "running",
      current_benchmark: "optcarrot",
      progress_pct: 45,
      message: "Running benchmark"
    )

    assert_equal "running", task.status
    assert_equal "running", task.heartbeat_status
    assert_equal "optcarrot", task.current_benchmark
    assert_equal 45, task.progress_pct
    assert_equal "Running benchmark", task.heartbeat_message
  end

  test "complete! marks task as completed" do
    task = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-123")
    task.complete!("results/123/task_1_result.tar.gz")

    assert_equal "completed", task.status
    assert_equal "results/123/task_1_result.tar.gz", task.s3_result_key
    assert_equal "finished", task.heartbeat_status
    assert_equal 100, task.progress_pct
  end

  test "fail! marks task as failed with error details" do
    task = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-123")
    task.fail!(
      error_type: "benchmark_error",
      error_message: "Benchmark failed to run",
      s3_error_key: "errors/123/task_1_error.tar.gz"
    )

    assert_equal "failed", task.status
    assert_equal "benchmark_error", task.error_type
    assert_equal "Benchmark failed to run", task.error_message
    assert_equal "errors/123/task_1_error.tar.gz", task.s3_error_key
    assert_equal "error", task.heartbeat_status
  end

  test "mark_timeout_failed! marks task as failed due to timeout" do
    task = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-123")
    task.mark_timeout_failed!

    assert_equal "failed", task.status
    assert_equal "timeout", task.error_type
    assert task.error_message.include?("No heartbeat received")
  end

  test "stale_heartbeats scope finds tasks with old heartbeats" do
    task1 = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task1.claim!("runner-123")

    task2 = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)
    task2.claim!("runner-456")
    task2.update_column(:heartbeat_at, 3.minutes.ago)

    stale = Task.stale_heartbeats

    assert_not_includes stale, task1
    assert_includes stale, task2
  end

  test "for_provider_and_type scope filters correctly" do
    aws_task = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    azure_task = @run.tasks.create!(provider: "azure", instance_type: "Standard_D2pls_v6", run_number: 1)

    aws_results = Task.for_provider_and_type("aws", "c8g.medium")

    assert_includes aws_results, aws_task
    assert_not_includes aws_results, azure_task
  end
end
