require "test_helper"

class GzipBuilderJobTest < ActiveJob::TestCase
  def stub_storage_service(return_value: nil, raise_error: nil, &block)
    original_method = StorageService.method(:collect_all_results)

    StorageService.define_singleton_method(:collect_all_results) do |run|
      raise raise_error if raise_error
      return_value
    end

    yield
  ensure
    StorageService.define_singleton_method(:collect_all_results, original_method)
  end

  test "collects results and marks run as completed" do
    run = Run.create!(ruby_version: "3.4.7", tasks_per_instance_type: 1, status: "running")
    task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-1")
    task.complete!("results/#{run.external_id}/task_1.tar.gz")

    stub_storage_service(return_value: "http://example.com/results.tar.gz") do
      GzipBuilderJob.perform_now(run.id)
    end

    run.reload
    assert_equal "completed", run.status
    assert_equal "http://example.com/results.tar.gz", run.gzip_url
  end

  test "marks cancelled run as cancelled after collecting results" do
    run = Run.create!(ruby_version: "3.4.7", tasks_per_instance_type: 1, status: "cancelled")
    task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-1")
    task.complete!("results/#{run.external_id}/task_1.tar.gz")

    stub_storage_service(return_value: "http://example.com/results.tar.gz") do
      GzipBuilderJob.perform_now(run.id)
    end

    run.reload
    assert_equal "cancelled", run.status
    assert_equal "http://example.com/results.tar.gz", run.gzip_url
  end

  test "skips already completed runs" do
    run = Run.create!(ruby_version: "3.4.7", tasks_per_instance_type: 1, status: "completed", gzip_url: "http://existing.com/results.tar.gz")

    collect_called = false
    original_method = StorageService.method(:collect_all_results)
    StorageService.define_singleton_method(:collect_all_results) do |r|
      collect_called = true
      "http://new.com/results.tar.gz"
    end

    begin
      GzipBuilderJob.perform_now(run.id)
    ensure
      StorageService.define_singleton_method(:collect_all_results, original_method)
    end

    run.reload
    assert_equal false, collect_called
    assert_equal "completed", run.status
    assert_equal "http://existing.com/results.tar.gz", run.gzip_url
  end

  test "marks run as completed even when storage collection fails" do
    run = Run.create!(ruby_version: "3.4.7", tasks_per_instance_type: 1, status: "running")
    task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-1")
    task.complete!("results/#{run.external_id}/task_1.tar.gz")

    stub_storage_service(raise_error: "S3 connection failed") do
      GzipBuilderJob.perform_now(run.id)
    end

    run.reload
    assert_equal "completed", run.status
    assert_nil run.gzip_url
  end

  test "marks cancelled run as cancelled even when storage collection fails" do
    run = Run.create!(ruby_version: "3.4.7", tasks_per_instance_type: 1, status: "cancelled")
    task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    task.claim!("runner-1")
    task.complete!("results/#{run.external_id}/task_1.tar.gz")

    stub_storage_service(raise_error: "S3 connection failed") do
      GzipBuilderJob.perform_now(run.id)
    end

    run.reload
    assert_equal "cancelled", run.status
    assert_nil run.gzip_url
  end
end
