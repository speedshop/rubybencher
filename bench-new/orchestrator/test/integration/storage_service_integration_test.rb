require "test_helper"
require "tempfile"

# Integration tests for StorageService with MinIO
# Requires MinIO to be running on localhost:9000
class StorageServiceIntegrationTest < ActiveSupport::TestCase
  setup do
    StorageService.reset!
    @run = Run.create!(ruby_version: "3.4.7", tasks_per_instance_type: 1)
    @task = @run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    @task.claim!("runner-1")
  end

  test "generate_presigned_urls creates working upload URLs" do
    urls = StorageService.generate_presigned_urls(run_id: @run.external_id, task_id: @task.id)

    assert urls[:result_upload_url].present?
    assert urls[:error_upload_url].present?
    assert urls[:result_key].present?
    assert urls[:error_key].present?

    # Verify the URLs can be used to upload
    Tempfile.create("test_result") do |f|
      f.write("test content")
      f.rewind

      uri = URI(urls[:result_upload_url])
      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Put.new(uri.request_uri)
      request["Content-Type"] = "application/gzip"
      request.body = f.read

      response = http.request(request)
      assert response.is_a?(Net::HTTPSuccess), "Upload should succeed: #{response.code} #{response.message}"
    end
  end

  test "result_url creates working download URLs for uploaded content" do
    # Upload a file first
    urls = StorageService.generate_presigned_urls(run_id: @run.external_id, task_id: @task.id)

    test_content = "test benchmark result content"
    uri = URI(urls[:result_upload_url])
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Put.new(uri.request_uri)
    request["Content-Type"] = "application/gzip"
    request.body = test_content
    http.request(request)

    # Now get the download URL and verify content
    download_url = StorageService.result_url(urls[:result_key])
    assert download_url.present?

    download_uri = URI(download_url)
    download_response = Net::HTTP.get_response(download_uri)

    assert download_response.is_a?(Net::HTTPSuccess), "Download should succeed"
    assert_equal test_content, download_response.body
  end

  test "collect_all_results creates combined tarball from task results" do
    # Create a mock tarball and upload it
    tarball_content = create_test_tarball_with_results

    urls = StorageService.generate_presigned_urls(run_id: @run.external_id, task_id: @task.id)

    uri = URI(urls[:result_upload_url])
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Put.new(uri.request_uri)
    request["Content-Type"] = "application/gzip"
    request.body = tarball_content
    http.request(request)

    # Mark task as completed with the S3 key
    @task.complete!(urls[:result_key])

    # Now collect all results
    combined_url = StorageService.collect_all_results(@run)

    assert combined_url.present?, "Should return a URL for the combined results"
    assert combined_url.include?("combined_results.tar.gz")
  end

  private

  def create_test_tarball_with_results
    require "rubygems/package"
    require "stringio"
    require "zlib"

    output = StringIO.new
    gz = Zlib::GzipWriter.new(output)
    tar = Gem::Package::TarWriter.new(gz)

    # Add output.txt
    output_txt = "Mock benchmark output"
    tar.add_file_simple("output.txt", 0644, output_txt.bytesize) { |io| io.write(output_txt) }

    # Add metadata.json
    metadata = { provider: "test", instance_type: "test-instance", ruby_version: "3.4.7" }.to_json
    tar.add_file_simple("metadata.json", 0644, metadata.bytesize) { |io| io.write(metadata) }

    tar.close
    gz.close
    output.string
  end
end
