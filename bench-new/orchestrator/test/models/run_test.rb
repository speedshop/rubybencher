require "test_helper"

class RunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "creates run with external_id" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)

    assert run.external_id.present?
    assert run.running?
  end

  test "validates presence of required fields" do
    run = Run.new

    assert_not run.valid?
    assert_includes run.errors[:ruby_version], "can't be blank"
    assert_includes run.errors[:runs_per_instance_type], "can't be blank"
  end

  test "validates runs_per_instance_type is positive" do
    run = Run.new(ruby_version: "3.4.7", runs_per_instance_type: 0)

    assert_not run.valid?
    assert_includes run.errors[:runs_per_instance_type], "must be greater than 0"
  end

  test "validates status is valid" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    run.status = "invalid"

    assert_not run.valid?
    assert_includes run.errors[:status], "is not included in the list"
  end

  test "complete! changes status to completed" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    run.complete!

    assert run.completed?
    assert_equal "completed", run.status
  end

  test "cancel! changes status to cancelled" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    run.cancel!

    assert run.cancelled?
    assert_equal "cancelled", run.status
  end

  test "cancel! cancels all pending tasks" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    task1 = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task2 = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)
    task3 = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 3)

    run.cancel!

    assert_equal "cancelled", task1.reload.status
    assert_equal "cancelled", task2.reload.status
    assert_equal "cancelled", task3.reload.status
  end

  test "cancel! cancels claimed and running tasks" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    pending_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    claimed_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)
    claimed_task.claim!("runner-1")
    running_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 3)
    running_task.claim!("runner-2")
    running_task.update!(status: "running")

    run.cancel!

    assert_equal "cancelled", pending_task.reload.status
    assert_equal "cancelled", claimed_task.reload.status
    assert_equal "cancelled", running_task.reload.status
  end

  test "cancel! does not change completed or failed tasks" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    completed_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    completed_task.claim!("runner-1")
    completed_task.complete!("results/1/task_1.tar.gz")
    failed_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)
    failed_task.claim!("runner-2")
    failed_task.fail!(error_type: "timeout", error_message: "Timed out")
    pending_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 3)

    run.cancel!

    assert_equal "completed", completed_task.reload.status
    assert_equal "failed", failed_task.reload.status
    assert_equal "cancelled", pending_task.reload.status
  end

  test "cancel! enqueues GzipBuilderJob" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)
    run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)

    assert_enqueued_with(job: GzipBuilderJob, args: [run.id]) do
      run.cancel!
    end
  end

  test "current scope returns most recent running run" do
    old_run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    old_run.complete!
    sleep 1

    current_run = Run.create!(ruby_version: "3.4.8", runs_per_instance_type: 3)

    assert_equal current_run, Run.current
  end

  test "maybe_finalize! enqueues gzip builder when all tasks are done" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)
    task1 = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task2 = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)

    task1.claim!("runner-1")
    task1.complete!("results/1/task_1.tar.gz")
    task2.claim!("runner-2")
    task2.fail!(error_type: "timeout", error_message: "Timed out")

    assert_enqueued_with(job: GzipBuilderJob, args: [run.id]) do
      run.maybe_finalize!
    end
  end

  test "maybe_finalize! does nothing when pending tasks exist" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)
    run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task2 = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)
    task2.claim!("runner-2")
    task2.complete!("results/1/task_2.tar.gz")

    assert_no_enqueued_jobs(only: GzipBuilderJob) do
      run.maybe_finalize!
    end
  end

  test "maybe_finalize! does nothing when claimed tasks exist" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)
    task1 = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task1.claim!("runner-1")
    task2 = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)
    task2.claim!("runner-2")
    task2.complete!("results/1/task_2.tar.gz")

    assert_no_enqueued_jobs(only: GzipBuilderJob) do
      run.maybe_finalize!
    end
  end

  test "maybe_finalize! does nothing when run is not running" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 1)
    task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-1")
    task.complete!("results/1/task_1.tar.gz")
    run.complete!

    assert_no_enqueued_jobs(only: GzipBuilderJob) do
      run.maybe_finalize!
    end
  end
end
