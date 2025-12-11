class TasksController < ApplicationController
  include ApiAuthentication

  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_api_request!, only: [:index]

  def index
    run = find_run

    unless run
      render json: { error: 'Run not found' }, status: :not_found
      return
    end

    tasks = run.tasks.order(:id)

    render json: {
      run_id: run.external_id,
      tasks: tasks.map { |t| task_detail_json(t) }
    }
  end

  def claim
    unless params[:provider].present? && params[:instance_type].present? && params[:runner_id].present?
      render json: { error: 'Missing required parameters' }, status: :bad_request
      return
    end

    run = find_run

    unless run
      render json: { error: 'Run not found' }, status: :not_found
      return
    end

    unless run.running?
      render json: { status: 'done', message: 'Run is not running' }
      return
    end

    task = nil

    ActiveRecord::Base.transaction do
      task = run.tasks
        .for_provider_and_type(params[:provider], params[:instance_type])
        .pending
        .lock
        .first

      if task.nil?
        in_progress = run.tasks
          .for_provider_and_type(params[:provider], params[:instance_type])
          .where(status: ['claimed', 'running'])
          .exists?

        if in_progress
          render json: { status: 'wait', retry_after_seconds: 30 }
          return
        else
          render json: { status: 'done' }
          return
        end
      end

      task.claim!(params[:runner_id])
    end

    presigned_urls = StorageService.generate_presigned_urls(
      run_id: run.external_id,
      task_id: task.id
    )

    render json: {
      status: 'assigned',
      task: {
        id: task.id,
        provider: task.provider,
        instance_type: task.instance_type,
        run_number: task.run_number,
        ruby_version: run.ruby_version
      },
      presigned_urls: presigned_urls
    }
  end

  def heartbeat
    task = Task.find(params[:id])

    unless params[:runner_id] == task.runner_id
      render json: { error: 'Invalid runner_id' }, status: :forbidden
      return
    end

    unless params[:status].present?
      render json: { error: 'Missing status parameter' }, status: :bad_request
      return
    end

    task.update_heartbeat!(
      heartbeat_status: params[:status],
      current_benchmark: params[:current_benchmark],
      progress_pct: params[:progress_pct],
      message: params[:message]
    )

    render json: { message: 'Heartbeat received' }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Task not found' }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :bad_request
  end

  def complete
    task = Task.find(params[:id])

    unless params[:runner_id] == task.runner_id
      render json: { error: 'Invalid runner_id' }, status: :forbidden
      return
    end

    unless params[:s3_result_key].present?
      render json: { error: 'Missing s3_result_key parameter' }, status: :bad_request
      return
    end

    task.complete!(params[:s3_result_key])

    check_run_completion(task.run)

    render json: { message: 'Task marked as completed' }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Task not found' }, status: :not_found
  end

  def fail
    task = Task.find(params[:id])

    unless params[:runner_id] == task.runner_id
      render json: { error: 'Invalid runner_id' }, status: :forbidden
      return
    end

    unless params[:error_type].present? && params[:error_message].present?
      render json: { error: 'Missing error_type or error_message parameter' }, status: :bad_request
      return
    end

    task.fail!(
      error_type: params[:error_type],
      error_message: params[:error_message],
      s3_error_key: params[:s3_error_key]
    )

    check_run_completion(task.run)

    render json: { message: 'Task marked as failed' }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Task not found' }, status: :not_found
  end

  private

  def find_run
    run_id = params[:run_id] || params[:id]
    Run.find_by(external_id: run_id) || Run.find_by(id: run_id)
  end

  def task_detail_json(task)
    {
      id: task.id,
      provider: task.provider,
      instance_type: task.instance_type,
      run_number: task.run_number,
      status: task.status,
      runner_id: task.runner_id,
      claimed_at: task.claimed_at&.iso8601,
      heartbeat_at: task.heartbeat_at&.iso8601,
      heartbeat_status: task.heartbeat_status,
      heartbeat_message: task.heartbeat_message,
      current_benchmark: task.current_benchmark,
      progress_pct: task.progress_pct,
      error_type: task.error_type,
      error_message: task.error_message
    }
  end

  def check_run_completion(run)
    return unless run.running?

    all_done = run.tasks.where(status: ['pending', 'claimed', 'running']).count.zero?

    if all_done
      GzipBuilderJob.perform_later(run.id)
    end
  end
end
