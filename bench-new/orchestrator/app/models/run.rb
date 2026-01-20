class Run < ApplicationRecord
  NO_CLAIMS_TIMEOUT = 10.minutes

  has_many :tasks, dependent: :destroy

  validates :ruby_version, presence: true
  validates :runs_per_instance_type, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: %w[running completed cancelled failed] }
  validates :external_id, presence: true, uniqueness: true

  before_validation :set_external_id, on: :create

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

  def fail_if_unclaimed!(timeout: NO_CLAIMS_TIMEOUT)
    return unless running?
    return unless tasks.exists?
    return if tasks.where.not(status: "pending").exists?
    return if created_at > timeout.ago

    fail_unclaimed_tasks!
  end

  def maybe_finalize!
    return unless running?
    return if tasks.where(status: %w[pending claimed running]).exists?

    GzipBuilderJob.perform_later(id)
  end

  private

  def fail_unclaimed_tasks!
    transaction do
      tasks.pending.update_all(
        status: "failed",
        error_type: "no_claims",
        error_message: "No tasks claimed within 10 minutes",
        heartbeat_status: "error"
      )
      update!(status: "failed")
    end
  end

  def set_external_id
    self.external_id ||= "#{Time.current.to_i}#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}"
  end
end
