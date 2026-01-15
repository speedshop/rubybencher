class DashboardController < ApplicationController
  def index
    @runs = Run.order(created_at: :desc).limit(100)
    @run = find_run(@runs)
    @tasks = @run&.tasks&.order(created_at: :desc) || []
    @task_stats = calculate_task_stats(@run)
  end

  def current_run_frame
    @run = find_run
    render partial: "current_run_frame"
  end

  def tasks_frame
    @run = find_run
    @tasks = @run&.tasks&.order(created_at: :desc) || []
    @task_stats = calculate_task_stats(@run)
    render partial: "tasks_frame"
  end

  private

  def find_run(runs = nil)
    run_id = params[:run_id]
    if run_id.present?
      return Run.find_by(external_id: run_id) || Run.find_by(id: run_id)
    end

    runs&.first || Run.order(created_at: :desc).first
  end

  def calculate_task_stats(run)
    return {} unless run

    tasks_by_status = run.tasks.group(:status).count

    {
      total: run.tasks.count,
      pending: tasks_by_status["pending"] || 0,
      claimed: tasks_by_status["claimed"] || 0,
      running: tasks_by_status["running"] || 0,
      completed: tasks_by_status["completed"] || 0,
      failed: tasks_by_status["failed"] || 0
    }
  end
end
