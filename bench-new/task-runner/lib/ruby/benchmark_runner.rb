# frozen_string_literal: true

module TaskRunner
  class BenchmarkRunner
    RUBY_BENCH_REPO = "https://github.com/ruby/ruby-bench.git"
    RUBY_BENCH_DIR = "/tmp/ruby-bench"

    def initialize(work_dir:, ruby_version:, mock_mode:, script_dir:, logger:, &progress_callback)
      @work_dir = work_dir
      @ruby_version = ruby_version
      @mock_mode = mock_mode
      @script_dir = script_dir
      @logger = logger
      @progress_callback = progress_callback
    end

    def run
      if @mock_mode
        run_mock_benchmark
      else
        run_ruby_bench
      end
    end

    private

    def run_mock_benchmark
      @logger.info "Running MOCK benchmark with Ruby #{@ruby_version}..."
      report_progress("mock_benchmark", 0, "Starting mock benchmark")

      output_file = File.join(@work_dir, "output.txt")
      mock_script = File.join(@script_dir, "mock", "benchmark.sh")

      success = system(mock_script, output_file, "/dev/null")

      if success
        @logger.info "Mock benchmark completed successfully"
        report_progress("mock_benchmark", 100, "Mock benchmark complete")
        true
      else
        @logger.error "Mock benchmark failed"
        false
      end
    end

    def run_ruby_bench
      @logger.info "Running ruby-bench with Ruby #{@ruby_version}..."

      report_progress("ruby_bench", 5, "Cloning ruby-bench repository")

      # Clone ruby-bench
      FileUtils.rm_rf(RUBY_BENCH_DIR)
      unless run_command("git clone --depth 1 #{RUBY_BENCH_REPO} #{RUBY_BENCH_DIR}")
        @logger.error "Failed to clone ruby-bench"
        return false
      end

      report_progress("ruby_bench", 10, "Starting headline benchmarks")

      # Run benchmarks with output going to work_dir
      Dir.chdir(RUBY_BENCH_DIR) do
        # Force single-process mode for Puma-based benchmarks (lobsters, etc.)
        # to ensure consistent single-core measurements
        ENV["WEB_CONCURRENCY"] = "1"

        # Run headline benchmarks, output files go to current directory
        # Use --no-pinning to avoid taskset issues in containers
        # Run only YJIT (skip interpreter baseline) with headline benchmarks
        ruby_path = `which ruby`.strip
        cmd = "./run_benchmarks.rb --headline --no-pinning --out-path #{@work_dir} -e=yjit::#{ruby_path}"
        @logger.info "Executing: #{cmd}"

        unless run_command_with_output(cmd, File.join(@work_dir, "benchmark_output.txt"))
          @logger.error "Benchmark execution failed"
          return false
        end

        report_progress("ruby_bench", 90, "Collecting results")

        # Find the ruby-bench output files and copy with standardized names
        # ruby-bench creates output_NNN.{txt,json,csv} files
        output_files = Dir.glob(File.join(@work_dir, "output_*.txt"))
        if output_files.any?
          base = output_files.first.sub(/\.txt$/, "")
          FileUtils.cp("#{base}.txt", File.join(@work_dir, "output.txt")) if File.exist?("#{base}.txt")
          FileUtils.cp("#{base}.json", File.join(@work_dir, "output.json")) if File.exist?("#{base}.json")
          FileUtils.cp("#{base}.csv", File.join(@work_dir, "output.csv")) if File.exist?("#{base}.csv")
          @logger.info "Copied ruby-bench output files to standardized names"
        else
          @logger.warn "No ruby-bench output files found in #{@work_dir}"
        end
      end

      @logger.info "ruby-bench completed successfully"
      report_progress("ruby_bench", 100, "Benchmark complete")
      true
    end

    def run_command(cmd)
      @logger.debug "Running: #{cmd}"
      system(cmd)
    end

    def run_command_with_output(cmd, output_file)
      @logger.debug "Running: #{cmd} (output to #{output_file})"

      File.open(output_file, "w") do |f|
        f.puts "=== Ruby Benchmark Runner ==="
        f.puts "Command: #{cmd}"
        f.puts "Ruby Version: #{RUBY_VERSION}"
        f.puts "Date: #{Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")}"
        f.puts ""
        f.puts "=== Output ==="
        f.flush

        IO.popen("#{cmd} 2>&1", "r") do |io|
          io.each_line do |line|
            f.puts line
            f.flush
            @logger.debug line.chomp

            # Parse progress from ruby-bench output: Running benchmark "name" (X/Y)
            if line =~ /Running benchmark "([^"]+)" \((\d+)\/(\d+)\)/
              benchmark_name = $1
              current = $2.to_i
              total = $3.to_i
              # Progress from 10% to 90% based on benchmark number
              pct = 10 + ((current.to_f / total) * 80).to_i
              report_progress(benchmark_name, pct, "Running #{benchmark_name} (#{current}/#{total})")
            end
          end
        end

        f.puts ""
        f.puts "=== Exit Status: #{$?.exitstatus} ==="
      end

      $?.success?
    end

    def report_progress(benchmark_name, progress, message)
      @progress_callback&.call(benchmark_name, progress, message)
    end
  end
end
