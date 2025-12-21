ENV["RAILS_ENV"] ||= "test"

# Disable AWS config files to prevent SSO token issues in tests
ENV["AWS_SDK_CONFIG_OPT_OUT"] = "1"
ENV["AWS_CONFIG_FILE"] = "/dev/null"
ENV["AWS_SHARED_CREDENTIALS_FILE"] = "/dev/null"

# Set MinIO credentials for tests (before loading Rails environment)
ENV["AWS_ACCESS_KEY_ID"] ||= "minioadmin"
ENV["AWS_SECRET_ACCESS_KEY"] ||= "minioadmin"
ENV["AWS_REGION"] ||= "us-east-1"
ENV["S3_BUCKET_NAME"] ||= "railsbencher-results"
ENV["S3_ENDPOINT"] ||= "http://127.0.0.1:9000"
ENV["S3_UPLOAD_ENDPOINT"] ||= "http://127.0.0.1:9000"
ENV["S3_DOWNLOAD_ENDPOINT"] ||= "http://127.0.0.1:9000"
ENV["S3_FORCE_PATH_STYLE"] ||= "true"

require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Reset StorageService singleton between tests to ensure clean state
    setup do
      StorageService.reset! if defined?(StorageService)
    end
  end
end
