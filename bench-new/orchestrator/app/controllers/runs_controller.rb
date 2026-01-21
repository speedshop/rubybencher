class RunsController < ApplicationController
  include ApiAuthentication

  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_api_request!, only: [ :index, :show ]
  before_action :set_default_format

  def index
    @runs = Run.order(created_at: :desc).limit(100)
  end

  def create
    instance_types = parse_instance_types(params)

    if instance_types.empty?
      render json: { error: "At least one instance type must be specified" }, status: :bad_request
      return
    end

    @run = Run.new(
      ruby_version: params[:ruby_version],
      tasks_per_instance_type: tasks_per_instance_type(params),
      external_id: params[:run_id]
    )

    if @run.save
      @tasks = create_tasks(@run, instance_types)
      render :create, status: :created
    else
      render json: { error: @run.errors.full_messages }, status: :bad_request
    end
  end

  def show
    @run = find_run

    unless @run
      render json: { error: "Run not found" }, status: :not_found
      return
    end

    @tasks_by_status = @run.tasks.group(:status).count
  end

  def stop
    @run = find_run

    if @run.nil?
      render json: { error: "Run not found" }, status: :not_found
      return
    end

    unless @run.running?
      render json: { error: "Run is not running" }, status: :unprocessable_entity
      return
    end

    @run.cancel!
  end

  private

  def set_default_format
    request.format = :json unless params[:format]
  end

  def find_run
    Run.find_by(external_id: params[:id]) || Run.find_by(id: params[:id])
  end

  def tasks_per_instance_type(params)
    per_instance_type = params[:per_instance_type]
    return unless per_instance_type.is_a?(ActionController::Parameters) || per_instance_type.is_a?(Hash)

    per_instance_type[:tasks] || per_instance_type["tasks"]
  end

  def parse_instance_types(params)
    instance_types = []

    %w[aws azure local].each do |provider|
      if params[provider].present?
        params[provider].each do |item|
          # Support both new format (object with instance_type/alias) and legacy (string)
          instance_types << if item.is_a?(Hash) || item.is_a?(ActionController::Parameters)
            {
              provider: provider,
              instance_type: item[:instance_type] || item["instance_type"],
              instance_type_alias: item[:alias] || item["alias"]
            }
          else
            # Legacy: plain string
            { provider: provider, instance_type: item, instance_type_alias: item }
          end
        end
      end
    end

    instance_types
  end

  def create_tasks(run, instance_types)
    tasks = []

    instance_types.each do |config|
      (1..run.tasks_per_instance_type).each do |task_number|
        tasks << run.tasks.create!(
          provider: config[:provider],
          instance_type: config[:instance_type],
          instance_type_alias: config[:instance_type_alias],
          run_number: task_number,
          status: "pending"
        )
      end
    end

    tasks
  end
end
