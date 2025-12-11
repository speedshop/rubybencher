class GzipBuilderJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    run = Run.find(run_id)

    return unless run.running?

    Rails.logger.info("Building gzip for run #{run.external_id}")

    begin
      gzip_url = StorageService.collect_all_results(run)

      run.update!(
        gzip_url: gzip_url,
        status: 'completed'
      )

      Rails.logger.info("Successfully built gzip for run #{run.external_id}: #{gzip_url}")
    rescue => e
      Rails.logger.error("Failed to build gzip for run #{run.external_id}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end
end
