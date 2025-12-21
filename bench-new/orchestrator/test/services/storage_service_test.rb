require "test_helper"

class StorageServiceTest < ActiveSupport::TestCase
  setup do
    StorageService.reset!
  end

  test "generate_presigned_urls returns expected keys" do
    urls = StorageService.generate_presigned_urls(run_id: "test-run-123", task_id: 42)

    assert_equal "results/test-run-123/task_42_result.tar.gz", urls[:result_key]
    assert_equal "results/test-run-123/task_42_error.tar.gz", urls[:error_key]
    assert urls[:result_upload_url].present?
    assert urls[:error_upload_url].present?
  end

  test "generate_presigned_urls creates valid presigned URLs" do
    urls = StorageService.generate_presigned_urls(run_id: "run-abc", task_id: 1)

    assert urls[:result_upload_url].include?("railsbencher-results")
    assert urls[:result_upload_url].include?("task_1_result.tar.gz")
    assert urls[:error_upload_url].include?("task_1_error.tar.gz")
  end

  test "result_url returns nil for nil key" do
    result = StorageService.result_url(nil)

    assert_nil result
  end

  test "result_url generates presigned download URL" do
    url = StorageService.result_url("results/run-123/task_1_result.tar.gz")

    assert url.present?
    assert url.include?("railsbencher-results")
    assert url.include?("task_1_result.tar.gz")
  end

  test "reset! clears the singleton instance" do
    instance1 = StorageService.instance

    StorageService.reset!
    instance2 = StorageService.instance

    refute_same instance1, instance2
  end

  test "instance returns same object on repeated calls" do
    instance1 = StorageService.instance
    instance2 = StorageService.instance

    assert_same instance1, instance2
  end
end
