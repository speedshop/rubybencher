class HeartbeatMonitorJob < ApplicationJob
  queue_as :default

  def perform
    stale_tasks = Task.stale_heartbeats

    stale_tasks.each do |task|
      Rails.logger.info("Marking task #{task.id} as failed due to stale heartbeat")
      task.mark_timeout_failed!
    end

    Rails.logger.info("Heartbeat monitor checked #{Task.where(status: ['claimed', 'running']).count} active tasks, found #{stale_tasks.count} stale")
  end
end
