class Run < ApplicationRecord
  has_many :tasks, dependent: :destroy

  validates :ruby_version, presence: true
  validates :runs_per_instance_type, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: %w[running completed cancelled] }
  validates :external_id, presence: true, uniqueness: true

  before_validation :set_external_id, on: :create

  scope :running, -> { where(status: 'running') }

  def self.current
    running.order(created_at: :desc).first
  end

  def completed?
    status == 'completed'
  end

  def running?
    status == 'running'
  end

  def cancelled?
    status == 'cancelled'
  end

  def complete!
    update!(status: 'completed')
  end

  def cancel!
    transaction do
      tasks.incomplete.update_all(status: 'cancelled')
      update!(status: 'cancelled')
    end
    GzipBuilderJob.perform_later(id)
  end

  def maybe_finalize!
    return unless running?
    return if tasks.where(status: %w[pending claimed running]).exists?

    GzipBuilderJob.perform_later(id)
  end

  private

  def set_external_id
    self.external_id ||= "#{Time.current.to_i}#{SecureRandom.hex(4)}"
  end
end
