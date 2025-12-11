class Task < ApplicationRecord
  belongs_to :run

  VALID_STATUSES = %w[pending claimed running completed failed cancelled].freeze
  VALID_HEARTBEAT_STATUSES = %w[boot provision running uploading finished error].freeze

  validates :provider, presence: true
  validates :instance_type, presence: true
  validates :run_number, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: VALID_STATUSES }
  validates :heartbeat_status, inclusion: { in: VALID_HEARTBEAT_STATUSES }, allow_nil: true

  scope :pending, -> { where(status: 'pending') }
  scope :claimed, -> { where(status: 'claimed') }
  scope :running, -> { where(status: 'running') }
  scope :completed, -> { where(status: 'completed') }
  scope :failed, -> { where(status: 'failed') }
  scope :cancelled, -> { where(status: 'cancelled') }
  scope :incomplete, -> { where(status: %w[pending claimed running]) }
  scope :for_provider_and_type, ->(provider, instance_type) {
    where(provider: provider, instance_type: instance_type)
  }
  scope :stale_heartbeats, -> {
    where(status: ['claimed', 'running'])
      .where('heartbeat_at < ?', 2.minutes.ago)
  }

  def claimable?
    status == 'pending'
  end

  def claim!(runner_id)
    update!(
      status: 'claimed',
      runner_id: runner_id,
      claimed_at: Time.current,
      heartbeat_at: Time.current
    )
  end

  def update_heartbeat!(heartbeat_status:, current_benchmark: nil, progress_pct: nil, message: nil)
    updates = {
      heartbeat_at: Time.current,
      heartbeat_status: heartbeat_status,
      heartbeat_message: message
    }

    updates[:status] = 'running' if heartbeat_status == 'running' && status == 'claimed'
    updates[:current_benchmark] = current_benchmark if current_benchmark
    updates[:progress_pct] = progress_pct if progress_pct

    update!(updates)
  end

  def complete!(s3_result_key)
    update!(
      status: 'completed',
      s3_result_key: s3_result_key,
      heartbeat_status: 'finished',
      progress_pct: 100
    )
  end

  def fail!(error_type:, error_message:, s3_error_key: nil)
    update!(
      status: 'failed',
      error_type: error_type,
      error_message: error_message,
      s3_error_key: s3_error_key,
      heartbeat_status: 'error'
    )
  end

  def mark_timeout_failed!
    fail!(
      error_type: 'timeout',
      error_message: "No heartbeat received for 2 minutes. Last heartbeat: #{heartbeat_at}"
    )
  end
end
