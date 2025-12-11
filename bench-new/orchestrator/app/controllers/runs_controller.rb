class RunsController < ApplicationController
  include ApiAuthentication

  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_api_request!, only: [:index, :show]

  def index
    runs = Run.order(created_at: :desc).limit(100)

    render json: {
      runs: runs.map { |run| run_summary_json(run) }
    }
  end

  def create
    instance_types = parse_instance_types(params)

    if instance_types.empty?
      render json: { error: 'At least one instance type must be specified' }, status: :bad_request
      return
    end

    run = Run.new(
      ruby_version: params[:ruby_version],
      runs_per_instance_type: params[:runs_per_instance_type]
    )

    if run.save
      tasks = create_tasks(run, instance_types)

      render json: {
        run_id: run.external_id,
        tasks_created: tasks.count,
        tasks: tasks.map { |t| task_json(t) }
      }, status: :created
    else
      render json: { error: run.errors.full_messages }, status: :bad_request
    end
  end

  def show
    run = find_run

    unless run
      render json: { error: 'Run not found' }, status: :not_found
      return
    end

    render json: run_status_json(run)
  end

  def stop
    run = find_run

    if run.nil?
      render json: { error: 'Run not found' }, status: :not_found
      return
    end

    unless run.running?
      render json: { error: 'Run is not running' }, status: :unprocessable_entity
      return
    end

    run.cancel!
    render json: { message: 'Run cancelled successfully' }
  end

  private

  def find_run
    Run.find_by(external_id: params[:id]) || Run.find_by(id: params[:id])
  end

  def parse_instance_types(params)
    instance_types = []

    %w[aws azure local].each do |provider|
      if params[provider].present?
        params[provider].each do |instance_type|
          instance_types << { provider: provider, instance_type: instance_type }
        end
      end
    end

    instance_types
  end

  def create_tasks(run, instance_types)
    tasks = []

    instance_types.each do |config|
      (1..run.runs_per_instance_type).each do |run_number|
        tasks << run.tasks.create!(
          provider: config[:provider],
          instance_type: config[:instance_type],
          run_number: run_number,
          status: 'pending'
        )
      end
    end

    tasks
  end

  def task_json(task)
    {
      id: task.id,
      provider: task.provider,
      instance_type: task.instance_type,
      run_number: task.run_number,
      status: task.status
    }
  end

  def run_summary_json(run)
    {
      run_id: run.external_id,
      status: run.status,
      ruby_version: run.ruby_version,
      created_at: run.created_at.iso8601
    }
  end

  def run_status_json(run)
    tasks_by_status = run.tasks.group(:status).count

    {
      run_id: run.external_id,
      status: run.status,
      ruby_version: run.ruby_version,
      runs_per_instance_type: run.runs_per_instance_type,
      tasks: {
        total: run.tasks.count,
        pending: tasks_by_status['pending'] || 0,
        claimed: tasks_by_status['claimed'] || 0,
        running: tasks_by_status['running'] || 0,
        completed: tasks_by_status['completed'] || 0,
        failed: tasks_by_status['failed'] || 0
      },
      gzip_url: run.gzip_url
    }
  end
end
