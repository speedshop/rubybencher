require "test_helper"

class HeartbeatMonitorJobTest < ActiveJob::TestCase
  test "marks stale tasks as failed" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)
    task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-123")
    task.update!(heartbeat_at: 3.minutes.ago)

    HeartbeatMonitorJob.perform_now

    task.reload
    assert_equal "failed", task.status
    assert_equal "timeout", task.error_type
  end

  test "does not mark recent heartbeats as failed" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)
    task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-123")
    task.update!(heartbeat_at: 1.minute.ago)

    HeartbeatMonitorJob.perform_now

    task.reload
    assert_equal "claimed", task.status
  end

  test "enqueues gzip builder when last active task times out" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)

    completed_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    completed_task.claim!("runner-1")
    completed_task.complete!("results/1/task_1.tar.gz")

    stale_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)
    stale_task.claim!("runner-2")
    stale_task.update!(heartbeat_at: 3.minutes.ago)

    assert_enqueued_with(job: GzipBuilderJob, args: [run.id]) do
      HeartbeatMonitorJob.perform_now
    end
  end

  test "does not enqueue gzip builder when other tasks are still active" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)

    active_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    active_task.claim!("runner-1")
    active_task.update!(heartbeat_at: 1.minute.ago)

    stale_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)
    stale_task.claim!("runner-2")
    stale_task.update!(heartbeat_at: 3.minutes.ago)

    assert_no_enqueued_jobs(only: GzipBuilderJob) do
      HeartbeatMonitorJob.perform_now
    end
  end

  test "does not enqueue gzip builder when pending tasks remain" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)

    pending_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)

    stale_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)
    stale_task.claim!("runner-2")
    stale_task.update!(heartbeat_at: 3.minutes.ago)

    assert_no_enqueued_jobs(only: GzipBuilderJob) do
      HeartbeatMonitorJob.perform_now
    end

    pending_task.reload
    assert_equal "pending", pending_task.status
  end

  test "handles multiple runs with stale tasks independently" do
    run1 = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 1)
    task1 = run1.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task1.claim!("runner-1")
    task1.update!(heartbeat_at: 3.minutes.ago)

    run2 = Run.create!(ruby_version: "3.4.8", runs_per_instance_type: 1)
    task2 = run2.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task2.claim!("runner-2")
    task2.update!(heartbeat_at: 3.minutes.ago)

    assert_enqueued_jobs(2, only: GzipBuilderJob) do
      HeartbeatMonitorJob.perform_now
    end
  end
end
