# frozen_string_literal: true

module TaskRunner
  class Logger
    def initialize(debug_mode: false)
      @debug_mode = debug_mode
      # Ensure stdout is unbuffered so logs appear immediately in docker logs
      $stdout.sync = true
    end

    def info(message)
      puts "[INFO] #{message}"
    end

    def warn(message)
      $stderr.puts "[WARN] #{message}"
    end

    def error(message)
      $stderr.puts "[ERROR] #{message}"
    end

    def debug(message)
      puts "[DEBUG] #{message}" if @debug_mode
    end
  end
end
