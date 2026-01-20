class TasksController < ApplicationController
  include ApiAuthentication

  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_api_request!, only: [ :index ]
  before_action :set_default_format

  def index
    @run = find_run

    unless @run
      render json: { error: "Run not found" }, status: :not_found
      return
    end

    @run.fail_if_unclaimed!
    @tasks = @run.tasks.order(:id)
  end

  def claim
    unless params[:provider].present? && params[:instance_type].present? && params[:runner_id].present?
      render json: { error: "Missing required parameters" }, status: :bad_request
      return
    end

    @run = find_run

    unless @run
      render json: { error: "Run not found" }, status: :not_found
      return
    end

    @run.fail_if_unclaimed!

    unless @run.running?
      @status = "done"
      @message = "Run is not running"
      return
    end

    ActiveRecord::Base.transaction do
      @task = @run.tasks
        .for_provider_and_type(params[:provider], params[:instance_type])
        .pending
        .lock
        .first

      if @task.nil?
        in_progress = @run.tasks
          .for_provider_and_type(params[:provider], params[:instance_type])
          .where(status: [ "claimed", "running" ])
          .exists?

        @status = if in_progress
          "wait"
        else
          "done"
        end
        return
      end

      @task.claim!(params[:runner_id])
    end

    @presigned_urls = StorageService.generate_presigned_urls(
      run_id: @run.external_id,
      task_id: @task.id
    )

    @status = "assigned"
  end

  def heartbeat
    @task = Task.find(params[:id])

    unless params[:runner_id] == @task.runner_id
      render json: { error: "Invalid runner_id" }, status: :forbidden
      return
    end

    unless params[:status].present?
      render json: { error: "Missing status parameter" }, status: :bad_request
      return
    end

    @task.update_heartbeat!(
      heartbeat_status: params[:status],
      current_benchmark: params[:current_benchmark],
      progress_pct: params[:progress_pct],
      message: params[:message]
    )
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Task not found" }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :bad_request
  end

  def complete
    @task = Task.find(params[:id])

    unless params[:runner_id] == @task.runner_id
      render json: { error: "Invalid runner_id" }, status: :forbidden
      return
    end

    unless params[:s3_result_key].present?
      render json: { error: "Missing s3_result_key parameter" }, status: :bad_request
      return
    end

    @task.complete!(params[:s3_result_key])
    @task.run.maybe_finalize!
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Task not found" }, status: :not_found
  end

  def fail
    @task = Task.find(params[:id])

    unless params[:runner_id] == @task.runner_id
      render json: { error: "Invalid runner_id" }, status: :forbidden
      return
    end

    unless params[:error_type].present? && params[:error_message].present?
      render json: { error: "Missing error_type or error_message parameter" }, status: :bad_request
      return
    end

    @task.fail!(
      error_type: params[:error_type],
      error_message: params[:error_message],
      s3_error_key: params[:s3_error_key]
    )

    @task.run.maybe_finalize!
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Task not found" }, status: :not_found
  end

  private

  def set_default_format
    request.format = :json unless params[:format]
  end

  def find_run
    run_id = params[:run_id] || params[:id]
    Run.find_by(external_id: run_id) || Run.find_by(id: run_id)
  end
end
