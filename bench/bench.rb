#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
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

  def initialize
    @run_id = Time.now.strftime("%Y%m%d-%H%M%S")
    @results_path = File.join(RESULTS_DIR, @run_id)
    @failed_instances = []
    @successful_instances = []
    @instance_status = {}
    @status_mutex = Mutex.new
  end

  def run
    update_status(phase: "starting", run_id: @run_id)
    setup_results_directory

    terraform_apply
    outputs = terraform_outputs

    @ssh_key = File.expand_path(outputs["ssh_key_path"]["value"], TERRAFORM_DIR)
    @ssh_user = outputs["ssh_user"]["value"]
    @instances = outputs["instance_ips"]["value"]
    @instance_ids = outputs["instance_ids"]["value"]
    @instances_by_type = outputs["instances_by_type"]["value"]
    @replicas = outputs["replicas"]["value"]

    update_status(phase: "instances_ready", instances: @instances, instances_by_type: @instances_by_type)

    wait_for_ssh_ready
    wait_for_setup_complete
    run_benchmarks_by_type

    if @failed_instances.empty?
      update_status(phase: "destroying", message: "All benchmarks succeeded")
      terraform_destroy
      update_status(phase: "complete", results_path: @results_path, successful: @successful_instances)
      exit 0
    else
      update_status(
        phase: "failed",
        results_path: @results_path,
        failed: @failed_instances,
        successful: @successful_instances,
        ssh_key: @ssh_key,
        instances: @instances
      )
      # Don't destroy infrastructure for failed runs to allow debugging
      exit 1
    end
  end

  private

  def update_status(data)
    @status_mutex.synchronize do
      status = data.merge(updated_at: Time.now.iso8601)
      status[:instance_status] = @instance_status unless @instance_status.empty?
      tmp_file = "#{STATUS_FILE}.tmp"
      File.write(tmp_file, JSON.pretty_generate(status))
      File.rename(tmp_file, STATUS_FILE)
    end
  end

  def setup_results_directory
    FileUtils.mkdir_p(@results_path)
  end

  def terraform_apply
    update_status(phase: "terraform_apply")
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

  def terminate_instances(instance_keys)
    instance_ids = instance_keys.map { |key| @instance_ids[key] }.compact
    return if instance_ids.empty?

    system("aws ec2 terminate-instances --region us-east-1 --instance-ids #{instance_ids.join(" ")} > /dev/null 2>&1")
  end

  def wait_for_ssh_ready
    update_status(phase: "waiting_for_ssh", instances: @instances)
    threads = @instances.map do |instance_key, ip|
      Thread.new { wait_for_ssh(instance_key, ip) }
    end
    threads.each(&:join)
    update_status(phase: "ssh_ready", instances: @instances)
  end

  def wait_for_ssh(instance_key, ip)
    MAX_SSH_RETRIES.times do
      result = system("ssh -i #{@ssh_key} #{SSH_OPTIONS} #{@ssh_user}@#{ip} 'echo ready' 2>/dev/null")
      return true if result
      sleep SSH_RETRY_DELAY
    end
    false
  end

  def wait_for_setup_complete
    update_status(phase: "waiting_for_docker_setup", instances: @instances)
    threads = @instances.map do |instance_key, ip|
      Thread.new { wait_for_setup(instance_key, ip) }
    end
    threads.each(&:join)
    update_status(phase: "docker_ready", instances: @instances)
  end

  def wait_for_setup(instance_key, ip)
    30.times do
      result = ssh_command(ip, "test -f /home/ec2-user/.setup_complete && echo done")
      return true if result&.strip == "done"
      sleep 10
    end
    false
  end

  def run_benchmarks_by_type
    update_status(phase: "running_benchmarks", instances: @instances)

    # Each instance type gets its own coordinator thread
    type_threads = @instances_by_type.map do |type_name, type_instances|
      Thread.new do
        # Run all replicas of this type in parallel
        replica_threads = type_instances.map do |instance_key, ip|
          Thread.new { run_benchmark(instance_key, ip) }
        end
        replica_threads.each(&:join)

        # All replicas of this type are done - collect results and terminate
        collect_results_for_type(type_name, type_instances)
        terminate_instances(type_instances.keys)
      end
    end

    type_threads.each(&:join)
  end

  def run_benchmark(instance_key, ip)
    @instance_status[instance_key] = { status: "starting", benchmark: nil, progress: nil }
    update_status(phase: "running_benchmarks", instances: @instances)

    ssh_command(ip, "mkdir -p ~/results")

    # Write benchmark script to remote using base64 (avoids all quoting issues)
    # Note: nodejs is required for shipit benchmark (uses CoffeeScript/Sprockets)
    benchmark_script = <<~'SCRIPT'
      #!/bin/bash
      docker run --rm \
        -e RUBY_YJIT_ENABLE=1 \
        -v ~/results:/results \
        ruby:3.4 \
        bash -c "
          apt-get update && apt-get install -y nodejs npm > /dev/null 2>&1 &&
          git clone https://github.com/ruby/ruby-bench /ruby-bench &&
          cd /ruby-bench &&
          ./run_benchmarks.rb 2>&1 | tee /results/output.txt &&
          cp -r *.csv *.json /results/ 2>/dev/null || true
        "
    SCRIPT

    encoded_script = Base64.strict_encode64(benchmark_script)
    ssh_command(ip, "echo #{encoded_script} | base64 -d > ~/bench_runner.sh && chmod +x ~/bench_runner.sh")

    # Run benchmark in background on remote, capture PID for monitoring
    pid_result = ssh_command(ip, "nohup ~/bench_runner.sh > ~/results/nohup.log 2>&1 & echo $!")
    benchmark_pid = pid_result&.strip

    @instance_status[instance_key] = { status: "running", benchmark: nil, progress: "pulling image" }
    update_status(phase: "running_benchmarks", instances: @instances)

    # Poll for progress until complete - check if the nohup process is still running
    loop do
      sleep 10
      # Use double quotes to avoid quoting issues with ssh_command's single-quote wrapping
      progress = ssh_command(ip, "grep -o \"Running benchmark.*([0-9]*/[0-9]*)\" ~/results/output.txt 2>/dev/null | tail -1")
      if progress && (match = progress.match(/Running benchmark "([^"]+)" \((\d+)\/(\d+)\)/))
        @instance_status[instance_key] = { status: "running", benchmark: match[1], progress: "#{match[2]}/#{match[3]}" }
      end
      update_status(phase: "running_benchmarks", instances: @instances)

      # Check if the benchmark process is still running (either the shell or docker)
      process_check = ssh_command(ip, "ps -p #{benchmark_pid} -o pid= 2>/dev/null || docker ps -q 2>/dev/null | head -1")
      break if process_check&.strip&.empty?
    end

    # Check final result
    result = ssh_command(ip, "test -f ~/results/output.txt && grep -q \"Average of last\" ~/results/output.txt && echo success")

    @status_mutex.synchronize do
      if result&.strip == "success"
        @instance_status[instance_key] = { status: "completed", benchmark: nil, progress: nil }
        @successful_instances << instance_key
      else
        @instance_status[instance_key] = { status: "failed", benchmark: nil, progress: nil }
        @failed_instances << instance_key
      end
    end
    update_status(phase: "running_benchmarks", instances: @instances)
  end

  def collect_results_for_type(type_name, type_instances)
    type_instances.each do |instance_key, ip|
      # instance_key is like "c6g.medium-1" -> create dir "c6g-medium-1"
      instance_results_dir = File.join(@results_path, instance_key.gsub(".", "-"))
      FileUtils.mkdir_p(instance_results_dir)

      scp_cmd = "scp -i #{@ssh_key} #{SSH_OPTIONS} -r #{@ssh_user}@#{ip}:~/results/* #{instance_results_dir}/ 2>/dev/null"
      @status_mutex.synchronize do
        @failed_instances << instance_key unless system(scp_cmd) || @failed_instances.include?(instance_key)
      end
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
