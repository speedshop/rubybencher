# frozen_string_literal: true

require "json"
require "fileutils"
require "net/http"
require "uri"

module TaskRunner
  class Packager
    class << self
      def package_result(work_dir:, task_id:, provider:, instance_type:, ruby_version:, run_number:, start_time:, end_time:, runner_id:)
        result_dir = File.join(work_dir, "result")
        FileUtils.mkdir_p(result_dir)

        # Copy all files from work_dir to result_dir (excluding subdirectories we create)
        copy_work_files(work_dir, result_dir)

        metadata = create_metadata(
          task_id: task_id,
          provider: provider,
          instance_type: instance_type,
          ruby_version: ruby_version,
          run_number: run_number,
          start_time: start_time,
          end_time: end_time,
          status: "success",
          runner_id: runner_id
        )
        File.write(File.join(result_dir, "metadata.json"), JSON.pretty_generate(metadata))

        tarball = File.join(work_dir, "result.tar.gz")
        system("tar", "-czf", tarball, "-C", result_dir, ".")
        tarball
      end

      def package_error(work_dir:, task_id:, provider:, instance_type:, ruby_version:, run_number:, start_time:, end_time:, error_message:, runner_id:)
        error_dir = File.join(work_dir, "error")
        FileUtils.mkdir_p(error_dir)

        # Copy all files from work_dir to error_dir (excluding subdirectories we create)
        copy_work_files(work_dir, error_dir)

        File.write(File.join(error_dir, "error.txt"), error_message)

        metadata = create_metadata(
          task_id: task_id,
          provider: provider,
          instance_type: instance_type,
          ruby_version: ruby_version,
          run_number: run_number,
          start_time: start_time,
          end_time: end_time,
          status: "error",
          runner_id: runner_id
        )
        File.write(File.join(error_dir, "metadata.json"), JSON.pretty_generate(metadata))

        tarball = File.join(work_dir, "error.tar.gz")
        system("tar", "-czf", tarball, "-C", error_dir, ".")
        tarball
      end

      def upload(file_path, dest_url, logger: nil)
        if dest_url.start_with?("/")
          upload_local(file_path, dest_url, logger)
        else
          upload_s3(file_path, dest_url, logger)
        end
      end

      private

      def copy_work_files(work_dir, dest_dir)
        # Copy all files (not directories) from work_dir to dest_dir
        Dir.glob(File.join(work_dir, "*")).each do |path|
          next unless File.file?(path)
          FileUtils.cp(path, dest_dir)
        end
      end

      def create_metadata(task_id:, provider:, instance_type:, ruby_version:, run_number:, start_time:, end_time:, status:, runner_id:)
        {
          task_id: task_id,
          provider: provider,
          instance_type: instance_type,
          ruby_version: ruby_version,
          run: run_number,
          start_time: start_time,
          end_time: end_time,
          status: status,
          runner_id: runner_id
        }
      end

      def upload_local(file_path, dest_path, logger)
        logger&.info("Copying result to local storage...")
        FileUtils.mkdir_p(File.dirname(dest_path))
        FileUtils.cp(file_path, dest_path)
        logger&.info("Copy successful")
        true
      rescue StandardError => e
        logger&.error("Copy failed: #{e.message}")
        false
      end

      def upload_s3(file_path, url, logger)
        logger&.info("Uploading to S3...")

        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 120

        request = Net::HTTP::Put.new(uri.request_uri)
        request["Content-Type"] = "application/gzip"
        request.body = File.binread(file_path)

        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          logger&.info("Upload successful")
          true
        else
          logger&.error("Upload failed: #{response.code} #{response.message}")
          false
        end
      rescue StandardError => e
        logger&.error("Upload failed: #{e.message}")
        false
      end
    end
  end
end
