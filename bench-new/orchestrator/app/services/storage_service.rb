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
      @bucket = ENV.fetch('S3_BUCKET_NAME', 'railsbencher-results')
      @public_endpoint = ENV.fetch('S3_PUBLIC_ENDPOINT', @endpoint)

      @s3_client = build_client
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

      url = presign_get(key)

      if @public_endpoint.present? && @endpoint.present?
        url.sub(@endpoint, @public_endpoint)
      else
        url
      end
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

    def build_client
      options = {
        region: @region,
        credentials: @credentials
      }

      if @endpoint.present?
        options[:endpoint] = @endpoint
        options[:force_path_style] = true
      end

      Aws::S3::Client.new(options)
    end

    def presigner
      @presigner ||= Aws::S3::Presigner.new(client: @s3_client)
    end

    def presign_put(key)
      presigner.presigned_url(
        :put_object,
        bucket: @bucket,
        key: key,
        expires_in: 3600
      )
    end

    def presign_get(key)
      presigner.presigned_url(
        :get_object,
        bucket: @bucket,
        key: key,
        expires_in: 86400
      )
    end
  end
end
