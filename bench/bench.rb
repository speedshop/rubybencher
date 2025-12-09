#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "fileutils"
require "open3"
require "optparse"
require "set"
require "time"
require "timeout"

class BenchmarkOrchestrator
  TERRAFORM_DIR = File.expand_path("terraform", __dir__)
  RESULTS_DIR = File.expand_path("../results", __dir__)
  STATUS_FILE = File.expand_path("../status.json", __dir__)
  SSH_OPTIONS = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
  MAX_SSH_RETRIES = 30
  SSH_RETRY_DELAY = 10

  def initialize(results_folder: nil)
    @run_id = results_folder || Time.now.strftime("%Y%m%d-%H%M%S")
    @results_path = File.join(RESULTS_DIR, @run_id)
    @failed_instances = []
    @successful_instances = []
    @instance_status = {}
    @status_mutex = Mutex.new
  end

  def run
    update_status(phase: "starting", run_id: @run_id)
    setup_results_directory

    # Check for already completed instance types before provisioning
    @skip_types = completed_instance_types
    unless @skip_types.empty?
      puts "Skipping already completed instance types: #{@skip_types.join(", ")}"
    end

    terraform_apply
    outputs = terraform_outputs

    @ssh_key = File.expand_path(outputs["ssh_key_path"]["value"], TERRAFORM_DIR)
    @ssh_users = outputs["ssh_user"]["value"] # { "aws" => "ec2-user", "azure" => "azureuser" }
    @replicas = outputs["replicas"]["value"]

    # AWS instances
    @aws_instances = outputs["instance_ips"]["value"]
    @aws_instance_ids = outputs["instance_ids"]["value"]
    @aws_instances_by_type = filter_instances_by_type(outputs["instances_by_type"]["value"], @skip_types)

    # Azure instances
    @azure_instances = outputs["azure_instance_ips"]["value"]
    @azure_instance_ids = outputs["azure_instance_ids"]["value"]
    @azure_instances_by_type = filter_instances_by_type(outputs["azure_instances_by_type"]["value"], @skip_types)
    @azure_resource_group = outputs["azure_resource_group"]["value"]

    # Combined view (filtered)
    @instances_by_type = filter_instances_by_type(outputs["all_instances_by_type"]["value"], @skip_types)
    # Rebuild instances from filtered instances_by_type
    @instances = @instances_by_type.values.reduce({}, :merge)

    # Terminate instances for skipped types immediately to save costs
    unless @skip_types.empty?
      skipped_instance_keys = []
      outputs["all_instances_by_type"]["value"].each do |type_name, type_instances|
        if @skip_types.include?(type_name)
          skipped_instance_keys.concat(type_instances.keys)
        end
      end
      unless skipped_instance_keys.empty?
        puts "Terminating #{skipped_instance_keys.length} instances for skipped types..."
        terminate_instances(skipped_instance_keys)
      end
    end

    if @instances.empty?
      puts "All instance types already completed. Nothing to run."
      terraform_destroy
      update_status(phase: "complete", results_path: @results_path, successful: [], skipped: @skip_types)
      exit 0
    end

    update_status(phase: "instances_ready", instances: @instances, instances_by_type: @instances_by_type, skipped: @skip_types)

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

  def completed_instance_types
    return [] unless Dir.exist?(@results_path)

    # Check which instance types have completed results
    # Results are stored in dirs like "c6g-medium-1", "Standard-D32pls-v5-1"
    completed = Set.new
    Dir.glob(File.join(@results_path, "*")).each do |dir|
      next unless File.directory?(dir)

      # Check if this result dir has a successful output
      output_file = File.join(dir, "output.txt")
      next unless File.exist?(output_file)
      next unless File.read(output_file).include?("Average of last")

      # Extract instance type from dir name (e.g., "c6g-medium-1" -> "c6g.medium")
      basename = File.basename(dir)
      # Remove the replica suffix (-1, -2, -3)
      type_with_dashes = basename.sub(/-\d+$/, "")
      # Convert back: "c6g-medium" -> "c6g.medium", "Standard-D32pls-v5" -> "Standard_D32pls_v5"
      # AWS types use dots, Azure types use underscores
      if type_with_dashes.start_with?("Standard-")
        # Azure: Standard-D32pls-v5 -> Standard_D32pls_v5
        instance_type = type_with_dashes.gsub("-", "_")
      else
        # AWS: c6g-medium -> c6g.medium
        instance_type = type_with_dashes.sub("-", ".")
      end
      completed.add(instance_type)
    end
    completed.to_a
  end

  def filter_instances_by_type(instances_by_type, skip_types)
    return instances_by_type if skip_types.empty?

    instances_by_type.reject { |type_name, _| skip_types.include?(type_name) }
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
    # Separate AWS and Azure instances
    aws_keys = instance_keys.select { |key| @aws_instance_ids.key?(key) }
    azure_keys = instance_keys.select { |key| @azure_instance_ids.key?(key) }

    # Terminate AWS instances
    aws_ids = aws_keys.map { |key| @aws_instance_ids[key] }.compact
    unless aws_ids.empty?
      system("aws ec2 terminate-instances --region us-east-1 --instance-ids #{aws_ids.join(" ")} > /dev/null 2>&1")
    end

    # Terminate Azure instances
    azure_keys.each do |key|
      vm_name = "ruby-bench-#{key.gsub("_", "-")}"
      system("az vm delete --resource-group #{@azure_resource_group} --name #{vm_name} --yes --no-wait > /dev/null 2>&1")
    end

    # Update status to show instances are terminated
    @status_mutex.synchronize do
      instance_keys.each do |key|
        @instance_status[key] = { status: "terminated", benchmark: nil, progress: nil }
      end
    end
    update_status(phase: "running_benchmarks", instances: @instances)
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
    user = ssh_user_for(instance_key)
    MAX_SSH_RETRIES.times do
      result = system("ssh -i #{@ssh_key} #{SSH_OPTIONS} #{user}@#{ip} 'echo ready' 2>/dev/null")
      return true if result
      sleep SSH_RETRY_DELAY
    end
    false
  end

  def ssh_user_for(instance_key)
    @azure_instance_ids.key?(instance_key) ? @ssh_users["azure"] : @ssh_users["aws"]
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
    user = ssh_user_for(instance_key)
    30.times do
      result = ssh_command(instance_key, ip, "test -f /home/#{user}/.setup_complete && echo done")
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

    ssh_command(instance_key, ip, "mkdir -p ~/results")

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
    ssh_command(instance_key, ip, "echo #{encoded_script} | base64 -d > ~/bench_runner.sh && chmod +x ~/bench_runner.sh")

    # Run benchmark in background on remote, capture PID for monitoring
    pid_result = ssh_command(instance_key, ip, "nohup ~/bench_runner.sh > ~/results/nohup.log 2>&1 & echo $!")
    benchmark_pid = pid_result&.strip

    @instance_status[instance_key] = { status: "running", benchmark: nil, progress: "pulling image" }
    update_status(phase: "running_benchmarks", instances: @instances)

    # Poll for progress until complete - check if the nohup process is still running
    loop do
      sleep 10
      # Use double quotes to avoid quoting issues with ssh_command's single-quote wrapping
      progress = ssh_command(instance_key, ip, "grep -o \"Running benchmark.*([0-9]*/[0-9]*)\" ~/results/output.txt 2>/dev/null | tail -1")
      if progress && (match = progress.match(/Running benchmark "([^"]+)" \((\d+)\/(\d+)\)/))
        @instance_status[instance_key] = { status: "running", benchmark: match[1], progress: "#{match[2]}/#{match[3]}" }
      end
      update_status(phase: "running_benchmarks", instances: @instances)

      # Check if the benchmark process is still running (either the shell or docker)
      process_check = ssh_command(instance_key, ip, "ps -p #{benchmark_pid} -o pid= 2>/dev/null || docker ps -q 2>/dev/null | head -1")
      break if process_check&.strip&.empty?
    end

    # Check final result
    result = ssh_command(instance_key, ip, "test -f ~/results/output.txt && grep -q \"Average of last\" ~/results/output.txt && echo success")

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
      # instance_key is like "c6g.medium-1" or "Standard_D32pls_v5-1" -> create dir with dots/underscores replaced
      instance_results_dir = File.join(@results_path, instance_key.gsub(".", "-").gsub("_", "-"))
      FileUtils.mkdir_p(instance_results_dir)

      user = ssh_user_for(instance_key)
      scp_cmd = "scp -i #{@ssh_key} #{SSH_OPTIONS} -r #{user}@#{ip}:~/results/* #{instance_results_dir}/ 2>/dev/null"
      @status_mutex.synchronize do
        @failed_instances << instance_key unless system(scp_cmd) || @failed_instances.include?(instance_key)
      end
    end
  end

  def ssh_command(instance_key, ip, command, timeout_secs: 600)
    user = ssh_user_for(instance_key)
    full_cmd = "ssh -i #{@ssh_key} #{SSH_OPTIONS} #{user}@#{ip} '#{command}'"
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

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: bench.rb [options]"
  opts.on("--results-folder FOLDER", "Use existing results folder instead of creating new one") do |folder|
    options[:results_folder] = folder
  end
end.parse!

BenchmarkOrchestrator.new(**options).run
