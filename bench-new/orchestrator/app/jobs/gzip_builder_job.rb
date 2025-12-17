class GzipBuilderJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    run = Run.find(run_id)

    # Allow gzip building for running runs (normal completion) and cancelled runs (early stop)
    return if run.completed?

    Rails.logger.info("Building gzip for run #{run.external_id}")

    final_status = run.cancelled? ? 'cancelled' : 'completed'

    begin
      gzip_url = StorageService.collect_all_results(run)

      run.update!(
        gzip_url: gzip_url,
        status: final_status
      )

      Rails.logger.info("Successfully built gzip for run #{run.external_id}: #{gzip_url}")
    rescue => e
      Rails.logger.error("Failed to build gzip for run #{run.external_id}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))

      # Mark run with appropriate status even if gzip building fails
      # The individual task results are still available in S3
      run.update!(status: final_status)
      Rails.logger.info("Marked run #{run.external_id} as #{final_status} despite gzip build failure")
    end
  end
end
