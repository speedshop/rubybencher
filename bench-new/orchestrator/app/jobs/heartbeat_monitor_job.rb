class HeartbeatMonitorJob < ApplicationJob
  queue_as :default

  def perform
    stale_tasks = Task.stale_heartbeats.includes(:run)
    affected_runs = Set.new

    stale_tasks.each do |task|
      Rails.logger.info("Marking task #{task.id} as failed due to stale heartbeat")
      task.mark_timeout_failed!
      affected_runs << task.run
    end

    affected_runs.each(&:maybe_finalize!)

    Rails.logger.info("Heartbeat monitor checked #{Task.where(status: ['claimed', 'running']).count} active tasks, found #{stale_tasks.count} stale")
  end
end
