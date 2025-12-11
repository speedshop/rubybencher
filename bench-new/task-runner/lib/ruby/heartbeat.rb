# frozen_string_literal: true

module TaskRunner
  class Heartbeat
    INTERVAL = 30

    def initialize(api:, task_id:, runner_id:)
      @api = api
      @task_id = task_id
      @runner_id = runner_id
      @mutex = Mutex.new
      @status = "running"
      @message = nil
      @current_benchmark = nil
      @progress_pct = nil
      @running = false
      @thread = nil
    end

    def start
      @running = true
      @thread = Thread.new { heartbeat_loop }
    end

    def stop
      @running = false
      @thread&.join(5)
      @thread&.kill if @thread&.alive?
    end

    def update(status: nil, message: nil, current_benchmark: nil, progress_pct: nil)
      @mutex.synchronize do
        @status = status if status
        @message = message if message
        @current_benchmark = current_benchmark
        @progress_pct = progress_pct
      end
    end

    private

    def heartbeat_loop
      while @running
        status, message, benchmark, progress = current_state
        @api.heartbeat(@task_id, @runner_id, status, message: message, current_benchmark: benchmark, progress_pct: progress)
        sleep(INTERVAL)
      end
    rescue StandardError
      # Silently ignore heartbeat errors - the main loop will handle failures
    end

    def current_state
      @mutex.synchronize do
        [@status, @message, @current_benchmark, @progress_pct]
      end
    end
  end
end
