#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "time"
require "timeout"

class BenchmarkOrchestrator
  TERRAFORM_DIR = File.expand_path("terraform", __dir__)
  RESULTS_DIR = File.expand_path("../results", __dir__)
  STATUS_FILE = File.expand_path("../status.json", __dir__)
  SSH_OPTIONS = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
  MAX_SSH_RETRIES = 30
  SSH_RETRY_DELAY = 10
  NUM_RUNS = 3

  def initialize
    @run_id = Time.now.strftime("%Y%m%d-%H%M%S")
    @results_path = File.join(RESULTS_DIR, @run_id)
    @failed_runs = []
    @successful_runs = []
    @status_mutex = Mutex.new
  end

  def run
    update_status(phase: "starting", run_id: @run_id, total_runs: NUM_RUNS)
    setup_results_directory

    NUM_RUNS.times do |run_index|
      run_number = run_index + 1
      @current_run = run_number
      @current_run_path = File.join(@results_path, "run-#{run_number}")
      FileUtils.mkdir_p(@current_run_path)

      @failed_instances = []
      @successful_instances = []
      @instance_status = {}

      update_status(phase: "starting_run", run_id: @run_id, current_run: run_number, total_runs: NUM_RUNS)

      terraform_apply
      outputs = terraform_outputs

      @ssh_key = File.expand_path(outputs["ssh_key_path"]["value"], TERRAFORM_DIR)
      @ssh_user = outputs["ssh_user"]["value"]
      @instances = outputs["instance_ips"]["value"]

      update_status(phase: "instances_ready", current_run: run_number, total_runs: NUM_RUNS, instances: @instances)

      wait_for_ssh_ready
      wait_for_setup_complete
      run_benchmarks_parallel
      collect_results

      if @failed_instances.empty?
        update_status(phase: "destroying", current_run: run_number, total_runs: NUM_RUNS, message: "Run #{run_number} succeeded")
        terraform_destroy
        @successful_runs << run_number
      else
        update_status(
          phase: "run_failed",
          current_run: run_number,
          total_runs: NUM_RUNS,
          failed: @failed_instances,
          successful: @successful_instances,
          ssh_key: @ssh_key,
          instances: @instances
        )
        @failed_runs << { run: run_number, failed_instances: @failed_instances, instances: @instances }
        # Don't destroy infrastructure for failed runs to allow debugging
      end
    end

    if @failed_runs.empty?
      update_status(phase: "complete", results_path: @results_path, successful_runs: @successful_runs)
      exit 0
    else
      update_status(
        phase: "failed",
        results_path: @results_path,
        successful_runs: @successful_runs,
        failed_runs: @failed_runs
      )
      exit 1
    end
  end

  private

  def update_status(data)
    @status_mutex.synchronize do
      status = data.merge(updated_at: Time.now.iso8601)
      tmp_file = "#{STATUS_FILE}.tmp"
      File.write(tmp_file, JSON.pretty_generate(status))
      File.rename(tmp_file, STATUS_FILE)
    end
  end

  def setup_results_directory
    FileUtils.mkdir_p(@results_path)
  end

  def terraform_apply
    update_status(phase: "terraform_apply", current_run: @current_run, total_runs: NUM_RUNS)
    Dir.chdir(TERRAFORM_DIR) do
      system("terraform init -input=false") || abort("terraform init failed")
      system("terraform apply -auto-approve") || abort("terraform apply failed")
    end
  end

  def terraform_outputs
    Dir.chdir(TERRAFORM_DIR) do
      output, = Open3.capture2("terraform output -json")
      JSON.parse(output)
    end
  end

  def terraform_destroy
    Dir.chdir(TERRAFORM_DIR) do
      system("terraform destroy -auto-approve")
    end
  end

  def wait_for_ssh_ready
    update_status(phase: "waiting_for_ssh", current_run: @current_run, total_runs: NUM_RUNS, instances: @instances)
    threads = @instances.map do |type, ip|
      Thread.new { wait_for_ssh(type, ip) }
    end
    threads.each(&:join)
    update_status(phase: "ssh_ready", current_run: @current_run, total_runs: NUM_RUNS, instances: @instances)
  end

  def wait_for_ssh(type, ip)
    MAX_SSH_RETRIES.times do
      result = system("ssh -i #{@ssh_key} #{SSH_OPTIONS} #{@ssh_user}@#{ip} 'echo ready' 2>/dev/null")
      return true if result
      sleep SSH_RETRY_DELAY
    end
    false
  end

  def wait_for_setup_complete
    update_status(phase: "waiting_for_docker_setup", current_run: @current_run, total_runs: NUM_RUNS, instances: @instances)
    threads = @instances.map do |type, ip|
      Thread.new { wait_for_setup(type, ip) }
    end
    threads.each(&:join)
    update_status(phase: "docker_ready", current_run: @current_run, total_runs: NUM_RUNS, instances: @instances)
  end

  def wait_for_setup(type, ip)
    30.times do
      result = ssh_command(ip, "test -f /home/ec2-user/.setup_complete && echo done")
      return true if result&.strip == "done"
      sleep 10
    end
    false
  end

  def run_benchmarks_parallel
    update_status(phase: "running_benchmarks", current_run: @current_run, total_runs: NUM_RUNS, instances: @instances, instance_status: @instance_status)
    threads = @instances.map do |type, ip|
      Thread.new { run_benchmark(type, ip) }
    end
    threads.each(&:join)
  end

  def run_benchmark(type, ip)
    @instance_status[type] = { status: "starting", benchmark: nil, progress: nil }
    update_status(phase: "running_benchmarks", current_run: @current_run, total_runs: NUM_RUNS, instances: @instances, instance_status: @instance_status)

    ssh_command(ip, "mkdir -p ~/results")

    benchmark_cmd = <<~CMD.gsub("\n", " ")
      docker run --rm
      -e RUBY_YJIT_ENABLE=1
      -v ~/results:/results
      ruby:3.4
      bash -c "
        git clone https://github.com/ruby/ruby-bench /ruby-bench &&
        cd /ruby-bench &&
        ./run_benchmarks.rb 2>&1 | tee /results/output.txt &&
        cp -r *.csv *.json /results/ 2>/dev/null || true
      "
    CMD

    # Run benchmark in background on remote, then poll for progress
    ssh_command(ip, "nohup sh -c '#{benchmark_cmd}' > /dev/null 2>&1 & echo $!")

    @instance_status[type] = { status: "running", benchmark: nil, progress: nil }
    update_status(phase: "running_benchmarks", current_run: @current_run, total_runs: NUM_RUNS, instances: @instances, instance_status: @instance_status)

    # Poll for progress until complete
    loop do
      sleep 5
      progress = ssh_command(ip, "grep -o 'Running benchmark.*([0-9]*/[0-9]*)' ~/results/output.txt 2>/dev/null | tail -1")
      if progress && (match = progress.match(/Running benchmark "([^"]+)" \((\d+)\/(\d+)\)/))
        @instance_status[type] = { status: "running", benchmark: match[1], progress: "#{match[2]}/#{match[3]}" }
      end
      update_status(phase: "running_benchmarks", current_run: @current_run, total_runs: NUM_RUNS, instances: @instances, instance_status: @instance_status)

      # Check if benchmark finished (look for final summary or no docker running)
      done_check = ssh_command(ip, "docker ps -q 2>/dev/null | head -1")
      break if done_check&.strip&.empty?
    end

    # Check final result
    result = ssh_command(ip, "test -f ~/results/output.txt && grep -q 'Average of last' ~/results/output.txt && echo success")

    if result&.strip == "success"
      @instance_status[type] = { status: "completed", benchmark: nil, progress: nil }
      @successful_instances << type
    else
      @instance_status[type] = { status: "failed", benchmark: nil, progress: nil }
      @failed_instances << type
    end
    update_status(phase: "running_benchmarks", current_run: @current_run, total_runs: NUM_RUNS, instances: @instances, instance_status: @instance_status)
  end

  def collect_results
    update_status(phase: "collecting_results", current_run: @current_run, total_runs: NUM_RUNS, instances: @instances)
    @instances.each do |type, ip|
      instance_results_dir = File.join(@current_run_path, type.gsub(".", "-"))
      FileUtils.mkdir_p(instance_results_dir)

      scp_cmd = "scp -i #{@ssh_key} #{SSH_OPTIONS} -r #{@ssh_user}@#{ip}:~/results/* #{instance_results_dir}/ 2>/dev/null"
      @failed_instances << type unless system(scp_cmd) || @failed_instances.include?(type)
    end
  end

  def ssh_command(ip, command, timeout_secs: 600)
    full_cmd = "ssh -i #{@ssh_key} #{SSH_OPTIONS} #{@ssh_user}@#{ip} '#{command}'"
    output = nil
    status = nil
    Timeout.timeout(timeout_secs) do
      output, status = Open3.capture2e(full_cmd)
    end
    status.success? ? output : nil
  rescue Timeout::Error
    nil
  end
end

BenchmarkOrchestrator.new.run
