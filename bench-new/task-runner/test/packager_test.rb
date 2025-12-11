# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "json"

class PackagerTest < Minitest::Test
  def test_package_result_creates_tarball
    Dir.mktmpdir do |work_dir|
      File.write(File.join(work_dir, "output.txt"), "benchmark output")

      tarball = TaskRunner::Packager.package_result(
        work_dir: work_dir,
        task_id: 42,
        provider: "aws",
        instance_type: "c8g.medium",
        ruby_version: "3.4.0",
        run_number: 1,
        start_time: "2024-01-01T00:00:00Z",
        end_time: "2024-01-01T01:00:00Z",
        runner_id: "runner-123"
      )

      assert File.exist?(tarball)
      assert tarball.end_with?("result.tar.gz")

      extract_dir = File.join(work_dir, "extracted")
      FileUtils.mkdir_p(extract_dir)
      system("tar", "-xzf", tarball, "-C", extract_dir)

      assert File.exist?(File.join(extract_dir, "output.txt"))
      assert File.exist?(File.join(extract_dir, "metadata.json"))

      metadata = JSON.parse(File.read(File.join(extract_dir, "metadata.json")))
      assert_equal 42, metadata["task_id"]
      assert_equal "aws", metadata["provider"]
      assert_equal "success", metadata["status"]
    end
  end

  def test_package_error_creates_tarball
    Dir.mktmpdir do |work_dir|
      File.write(File.join(work_dir, "output.txt"), "partial output")

      tarball = TaskRunner::Packager.package_error(
        work_dir: work_dir,
        task_id: 42,
        provider: "aws",
        instance_type: "c8g.medium",
        ruby_version: "3.4.0",
        run_number: 1,
        start_time: "2024-01-01T00:00:00Z",
        end_time: "2024-01-01T00:30:00Z",
        error_message: "Benchmark crashed",
        runner_id: "runner-123"
      )

      assert File.exist?(tarball)
      assert tarball.end_with?("error.tar.gz")

      extract_dir = File.join(work_dir, "extracted")
      FileUtils.mkdir_p(extract_dir)
      system("tar", "-xzf", tarball, "-C", extract_dir)

      assert File.exist?(File.join(extract_dir, "error.txt"))
      assert_equal "Benchmark crashed", File.read(File.join(extract_dir, "error.txt"))

      metadata = JSON.parse(File.read(File.join(extract_dir, "metadata.json")))
      assert_equal "error", metadata["status"]
    end
  end

  def test_upload_local_copies_file
    Dir.mktmpdir do |dir|
      source = File.join(dir, "source.tar.gz")
      dest = File.join(dir, "subdir", "dest.tar.gz")

      File.write(source, "test content")

      result = TaskRunner::Packager.upload(source, dest)

      assert result
      assert File.exist?(dest)
      assert_equal "test content", File.read(dest)
    end
  end

  def test_upload_s3_sends_put_request
    stub_request(:put, "https://s3.amazonaws.com/bucket/results/42/result.tar.gz")
      .with(headers: { "Content-Type" => "application/gzip" })
      .to_return(status: 200)

    Dir.mktmpdir do |dir|
      source = File.join(dir, "result.tar.gz")
      File.write(source, "tarball content")

      result = TaskRunner::Packager.upload(
        source,
        "https://s3.amazonaws.com/bucket/results/42/result.tar.gz"
      )

      assert result
    end
  end

  def test_upload_s3_returns_false_on_failure
    stub_request(:put, "https://s3.amazonaws.com/bucket/results/42/result.tar.gz")
      .to_return(status: 500)

    Dir.mktmpdir do |dir|
      source = File.join(dir, "result.tar.gz")
      File.write(source, "tarball content")

      result = TaskRunner::Packager.upload(
        source,
        "https://s3.amazonaws.com/bucket/results/42/result.tar.gz"
      )

      refute result
    end
  end
end
