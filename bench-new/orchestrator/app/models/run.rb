class Run < ApplicationRecord
  has_many :tasks, dependent: :destroy

  validates :ruby_version, presence: true
  validates :runs_per_instance_type, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: %w[running completed cancelled failed] }
  validates :external_id, presence: true, uniqueness: true

  before_validation :set_external_id, on: :create

  STALLED_RUN_TIMEOUT = 10.minutes

  scope :running, -> { where(status: "running") }

  def self.current
    running.order(created_at: :desc).first
  end

  def completed?
    status == "completed"
  end

  def running?
    status == "running"
  end

  def cancelled?
    status == "cancelled"
  end

  def failed?
    status == "failed"
  end

  def complete!
    update!(status: "completed")
  end

  def cancel!
    transaction do
      tasks.incomplete.update_all(status: "cancelled")
      update!(status: "cancelled")
    end
    GzipBuilderJob.perform_later(id)
  end

  def fail_if_stalled!
    return unless running?
    return unless created_at <= STALLED_RUN_TIMEOUT.ago
    return if tasks.where.not(status: "pending").exists?

    transaction do
      tasks.pending.update_all(
        status: "failed",
        error_type: "stalled",
        error_message: "No task claims received within #{STALLED_RUN_TIMEOUT.in_minutes} minutes",
        heartbeat_status: "error"
      )
      update!(status: "failed")
    end
  end

  def maybe_finalize!
    return unless running?
    return if tasks.where(status: %w[pending claimed running]).exists?

    GzipBuilderJob.perform_later(id)
  end

  private

  def set_external_id
    self.external_id ||= "#{Time.current.to_i}#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}"
  end
end
