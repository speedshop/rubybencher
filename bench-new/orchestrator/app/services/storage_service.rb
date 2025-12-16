class StorageService
  class << self
    def instance
      @instance ||= S3Storage.new
    end

    def generate_presigned_urls(run_id:, task_id:)
      instance.generate_presigned_urls(run_id: run_id, task_id: task_id)
    end

    def result_url(key)
      instance.result_url(key)
    end

    def collect_all_results(run)
      instance.collect_all_results(run)
    end

    def reset!
      @instance = nil
    end
  end

  class S3Storage
    def initialize
      require 'aws-sdk-s3'

      @credentials = Aws::Credentials.new(
        ENV.fetch('AWS_ACCESS_KEY_ID', 'minioadmin'),
        ENV.fetch('AWS_SECRET_ACCESS_KEY', 'minioadmin')
      )

      @region = ENV.fetch('AWS_REGION', 'us-east-1')
      @endpoint = ENV['S3_ENDPOINT']
      # Upload endpoint: used by task runners (inside Docker) to upload results
      # Should be reachable from inside Docker containers (e.g., host.docker.internal:9000)
      @upload_endpoint = ENV['S3_UPLOAD_ENDPOINT'] || ENV['S3_PUBLIC_ENDPOINT']
      # Download endpoint: used by master script (on host) to download results
      # Should be reachable from the host machine (e.g., localhost:9000)
      @download_endpoint = ENV['S3_DOWNLOAD_ENDPOINT'] || ENV['S3_PUBLIC_ENDPOINT']
      @bucket = ENV.fetch('S3_BUCKET_NAME', 'railsbencher-results')

      @s3_client = build_client
      @upload_s3_client = build_client(endpoint_override: @upload_endpoint) if @upload_endpoint.present?
      @download_s3_client = build_client(endpoint_override: @download_endpoint) if @download_endpoint.present?
    end

    def generate_presigned_urls(run_id:, task_id:)
      result_key = "results/#{run_id}/task_#{task_id}_result.tar.gz"
      error_key = "results/#{run_id}/task_#{task_id}_error.tar.gz"

      {
        result_upload_url: presign_put(result_key),
        error_upload_url: presign_put(error_key),
        result_key: result_key,
        error_key: error_key
      }
    end

    def result_url(key)
      return nil unless key
      presign_get(key)
    end

    def collect_all_results(run)
      output_path = Rails.root.join('tmp', 'storage', "run_#{run.external_id}_results.tar.gz")
      FileUtils.mkdir_p(output_path.dirname)

      temp_dir = Rails.root.join('tmp', "run_#{run.external_id}_download")
      FileUtils.mkdir_p(temp_dir)

      begin
        run.tasks.completed.each do |task|
          next unless task.s3_result_key

          local_file = temp_dir.join("task_#{task.id}_result.tar.gz")
          @s3_client.get_object(
            bucket: @bucket,
            key: task.s3_result_key,
            response_target: local_file
          )
        end

        system("tar", "-czf", output_path.to_s, "-C", temp_dir.to_s, ".")

        @s3_client.put_object(
          bucket: @bucket,
          key: "results/#{run.external_id}/combined_results.tar.gz",
          body: File.read(output_path)
        )

        result_url("results/#{run.external_id}/combined_results.tar.gz")
      ensure
        FileUtils.rm_rf(temp_dir)
        FileUtils.rm_f(output_path)
      end
    end

    private

    def build_client(endpoint_override: nil)
      options = {
        region: @region,
        credentials: @credentials
      }

      endpoint = endpoint_override || @endpoint
      if endpoint.present?
        options[:endpoint] = endpoint
        options[:force_path_style] = true
      end

      Aws::S3::Client.new(options)
    end

    def presigner
      @presigner ||= Aws::S3::Presigner.new(client: @s3_client)
    end

    # Presigner for upload URLs - used by task runners inside Docker containers
    def upload_presigner
      @upload_presigner ||= Aws::S3::Presigner.new(client: @upload_s3_client || @s3_client)
    end

    # Presigner for download URLs - used by master script on the host machine
    def download_presigner
      @download_presigner ||= Aws::S3::Presigner.new(client: @download_s3_client || @s3_client)
    end

    def presign_put(key)
      # Use upload presigner for task runner uploads (needs to be reachable from inside Docker)
      upload_presigner.presigned_url(
        :put_object,
        bucket: @bucket,
        key: key,
        expires_in: 3600
      )
    end

    def presign_get(key)
      # Use download presigner for master script downloads (needs to be reachable from host)
      download_presigner.presigned_url(
        :get_object,
        bucket: @bucket,
        key: key,
        expires_in: 86400
      )
    end
  end
end
