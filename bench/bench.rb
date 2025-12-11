#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "optparse"
require "securerandom"
require "set"
require "time"
require "openssl"
require "cgi"

class BenchmarkOrchestrator
  TERRAFORM_DIR = File.expand_path("terraform", __dir__)
  RESULTS_DIR = File.expand_path("../results", __dir__)
  STATUS_FILE = File.expand_path("../status.json", __dir__)
  INSTANCE_TYPES_FILE = File.expand_path("instance_types.json", __dir__)
  UPLOAD_CONFIG_FILE = File.join(TERRAFORM_DIR, "upload_config.json")
  SKIP_TYPES_FILE = File.join(TERRAFORM_DIR, "skip_types.json")
  RESULT_TIMEOUT = 7200 # seconds
  POLL_INTERVAL = 20

  def initialize(results_folder: nil, replicas: nil, aws_replicas: nil, azure_replicas: nil)
    @run_id = sanitize_run_id(results_folder || Time.now.strftime("%Y%m%d-%H%M%S"))
    @results_path = File.join(RESULTS_DIR, @run_id)
    default_replicas = replicas || ENV["TF_VAR_replicas"]
    @aws_replicas = (aws_replicas || ENV["TF_VAR_aws_replicas"] || default_replicas || "3").to_i
    @azure_replicas = (azure_replicas || ENV["TF_VAR_azure_replicas"] || default_replicas || "2").to_i
    @replicas_by_provider = {
      "aws" => @aws_replicas,
      "azure" => @azure_replicas
    }
    @default_replicas = default_replicas&.to_i
    @bucket = ENV.fetch("TF_VAR_results_bucket_name", "railsbencher-results")
    @aws_region = ENV.fetch("TF_VAR_aws_region", ENV.fetch("AWS_REGION", "us-east-1"))
    @failed_instances = []
    @successful_instances = []
    @status_mutex = Mutex.new
    @instance_status = {}
  end

  def run
    update_status(phase: "starting", run_id: @run_id)
    setup_results_directory

    @skip_types = completed_instance_types
    puts "Skipping already completed instance types: #{@skip_types.join(", ")}" unless @skip_types.empty?

    @instance_plan = build_instance_plan
    if @instance_plan.empty?
      puts "All instance types already completed. Nothing to run."
      update_status(phase: "complete", results_path: @results_path, successful: [], skipped: @skip_types)
      return
    end

    write_skip_file
    write_upload_config

    terraform_apply
    wait_for_results
    finalize_run
  rescue StandardError => e
    update_status(
      phase: "failed",
      run_id: @run_id,
      error: e.message,
      backtrace: e.backtrace&.take(5)
    )
    warn "Benchmark orchestrator failed: #{e.message}"
    exit 1
  ensure
    cleanup_temp_files
  end

  private

  def setup_results_directory
    FileUtils.mkdir_p(@results_path)
  end

  def sanitize_run_id(value)
    cleaned = value.to_s.gsub(/\e\[[0-9;]*m/, "") # strip ANSI
    cleaned = cleaned.strip
    cleaned.gsub(/[^A-Za-z0-9_.-]/, "_")
  end

  def load_instance_config
    JSON.parse(File.read(INSTANCE_TYPES_FILE))
  end

  def build_instance_plan
    config = load_instance_config
    plan = {}
    config.each do |provider, types|
      types.each_key do |type_name|
        next if skip_type?(provider, type_name)

        replicas = @replicas_by_provider[provider] || @default_replicas || 1
        (1..replicas).each do |replica|
          instance_key = "#{type_name}-#{replica}"
          plan[instance_key] = {
            provider: provider,
            type: type_name,
            replica: replica
          }
        end
      end
    end
    plan
  end

  def skip_type?(provider, type_name)
    @skip_types.include?(type_name) || @skip_types.include?("#{provider}:#{type_name}")
  end

  def completed_instance_types
    return [] unless Dir.exist?(@results_path)

    completed = Set.new
    Dir.glob(File.join(@results_path, "*")).each do |dir|
      next unless File.directory?(dir)
      output_file = File.join(dir, "output.txt")
      meta_file = File.join(dir, "meta.json")

      instance_type = nil
      if File.exist?(meta_file)
        meta = JSON.parse(File.read(meta_file)) rescue {}
        instance_type = meta["instance_type"] || meta["type"]
        provider = meta["provider"]
        if instance_type
          completed.add(instance_type)
          completed.add("#{provider}:#{instance_type}") if provider
        end
      end

      if instance_type.nil? && File.exist?(output_file) && File.read(output_file).include?("Average of last")
        base = File.basename(dir).sub(/-\d+$/, "")
        instance_type = if base.start_with?("Standard-")
          base.tr("-", "_")
        else
          base.sub("-", ".")
        end
      end

      completed.add(instance_type) if instance_type
    end
    completed.to_a
  end

  def write_skip_file
    if @skip_types.empty?
      FileUtils.rm_f(SKIP_TYPES_FILE)
    else
      File.write(SKIP_TYPES_FILE, JSON.pretty_generate(@skip_types))
    end
  end

  def write_upload_config
    config = {
      run_id: @run_id,
      bucket: @bucket,
      region: @aws_region,
      instances: {}
    }

    @instance_plan.each do |instance_key, meta|
      paths = object_paths(instance_key)
      config[:instances][instance_key] = meta.merge(
        result: {
          key: paths[:result_key],
          url: presign_url(paths[:result_key])
        },
        error: {
          key: paths[:error_key],
          url: presign_url(paths[:error_key])
        },
        heartbeat: {
          key: paths[:heartbeat_key],
          url: presign_url(paths[:heartbeat_key])
        },
        result_url: presign_url(paths[:result_key]),
        error_url: presign_url(paths[:error_key]),
        heartbeat_url: presign_url(paths[:heartbeat_key]),
        token: SecureRandom.hex(16)
      )
    end

    File.write(UPLOAD_CONFIG_FILE, JSON.pretty_generate(config))

    @instance_plan.each_key do |instance_key|
      @instance_status[instance_key] = { status: "pending" }
    end
  end

  def object_paths(instance_key)
    base = "runs/#{@run_id}/#{instance_key}"
    {
      result_key: "#{base}/result.tar.gz",
      error_key: "#{base}/error.tar.gz",
      heartbeat_key: "#{base}/heartbeat.json"
    }
  end

  def presign_url(key)
    access_key = ENV["AWS_ACCESS_KEY_ID"] || ENV["AWS_ACCESS_KEY"]
    secret_key = ENV["AWS_SECRET_ACCESS_KEY"] || ENV["AWS_SECRET_KEY"]
    token = ENV["AWS_SESSION_TOKEN"]
    raise "Missing AWS credentials" unless access_key && secret_key

    region = @aws_region
    service = "s3"
    algorithm = "AWS4-HMAC-SHA256"
    amz_date = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = amz_date[0, 8]
    host = "s3.#{region}.amazonaws.com"
    expires = 7200

    canonical_uri = "/" + uri_encode(@bucket, encode_slash: true) + "/" + uri_encode(key, encode_slash: true)

    credential_scope = "#{date_stamp}/#{region}/#{service}/aws4_request"
    credential = "#{access_key}/#{credential_scope}"

    query = {
      "X-Amz-Algorithm" => algorithm,
      "X-Amz-Credential" => credential,
      "X-Amz-Date" => amz_date,
      "X-Amz-Expires" => expires.to_s,
      "X-Amz-SignedHeaders" => "host"
    }
    query["X-Amz-Security-Token"] = token if token

    canonical_querystring = canonical_query(query)
    canonical_headers = "host:#{host}\n"
    signed_headers = "host"
    payload_hash = "UNSIGNED-PAYLOAD"

    canonical_request = [
      "PUT",
      canonical_uri,
      canonical_querystring,
      canonical_headers,
      signed_headers,
      payload_hash
    ].join("\n")

    string_to_sign = [
      algorithm,
      amz_date,
      credential_scope,
      OpenSSL::Digest::SHA256.hexdigest(canonical_request)
    ].join("\n")

    signing_key = sigv4_signing_key(secret_key, date_stamp, region, service)
    signature = OpenSSL::HMAC.hexdigest("sha256", signing_key, string_to_sign)

    signed_query = canonical_querystring + "&X-Amz-Signature=#{signature}"
    "https://#{host}#{canonical_uri}?#{signed_query}"
  end

  def canonical_query(hash)
    hash.sort.map do |k, v|
      "#{uri_encode(k, encode_slash: true)}=#{uri_encode(v, encode_slash: true)}"
    end.join("&")
  end

  def uri_encode(val, encode_slash: false)
    encoded = CGI.escape(val.to_s.encode("UTF-8"))
    encoded = encoded.gsub("+", "%20")
    encode_slash ? encoded : encoded.gsub("%2F", "/")
  end

  def sigv4_signing_key(secret_key, date_stamp, region, service)
    k_date = hmac("AWS4" + secret_key, date_stamp)
    k_region = hmac(k_date, region)
    k_service = hmac(k_region, service)
    hmac(k_service, "aws4_request")
  end

  def hmac(key, data)
    OpenSSL::HMAC.digest("sha256", key, data)
  end

  def terraform_apply
    update_status(phase: "terraform_init")
    terraform_stream(%w[terraform init -input=false], phase: "terraform_init")
    terraform_stream(%w[terraform apply -auto-approve], phase: "terraform_applying")
    update_status(phase: "instances_ready", run_id: @run_id, expected: @instance_plan.keys)
  end

  def terraform_destroy
    terraform_stream(%w[terraform destroy -auto-approve], phase: "destroying")
  end

  def terraform_stream(cmd, phase:)
    Dir.chdir(TERRAFORM_DIR) do
      Open3.popen2e(*cmd) do |_stdin, stdout_err, wait_thr|
        stdout_err.each_line do |line|
          print line
          update_status(phase: phase, terraform_output: line.strip)
        end
        exit_status = wait_thr.value
        abort("#{cmd.join(' ')} failed") unless exit_status.success?
      end
    end
  end

  def wait_for_results
    pending = @instance_plan.keys.dup
    update_status(
      phase: "waiting_for_results",
      run_id: @run_id,
      expected: @instance_plan.keys,
      pending: pending,
      successful: @successful_instances,
      failed: @failed_instances,
      next_poll_in: POLL_INTERVAL
    )

    deadline = Time.now + RESULT_TIMEOUT

    until pending.empty?
      pending.dup.each do |instance_key|
        update_heartbeat_status(instance_key)
        status = check_instance_result(instance_key)
        next if status == :pending

        pending.delete(instance_key)
      end

      update_status(
        phase: "waiting_for_results",
        run_id: @run_id,
        expected: @instance_plan.keys,
        pending: pending,
        successful: @successful_instances,
        failed: @failed_instances,
        next_poll_in: POLL_INTERVAL,
        last_poll_at: Time.now.iso8601
      )

      break if pending.empty? || Time.now > deadline
      sleep POLL_INTERVAL
    end

    unless pending.empty?
      pending.each do |instance_key|
        mark_failed(instance_key, "timeout")
      end
    end
  end

  def check_instance_result(instance_key)
    config = instance_upload_config(instance_key)
    return :pending unless config

    update_heartbeat_status(instance_key)

    if object_exists?(config[:result][:key])
      if download_and_extract(instance_key, config[:result][:key])
        mark_success(instance_key)
      else
        mark_failed(instance_key, "download failed")
      end
      :done
    elsif object_exists?(config[:error][:key])
      if download_error(instance_key, config[:error][:key])
        mark_failed(instance_key, "error upload")
      else
        mark_failed(instance_key, "error download failed")
      end
      :done
    else
      :pending
    end
  end

  def instance_upload_config(instance_key)
    @upload_config ||= JSON.parse(File.read(UPLOAD_CONFIG_FILE), symbolize_names: true)
    @upload_config[:instances][instance_key.to_sym] || @upload_config[:instances][instance_key]
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def object_exists?(key)
    cmd = [
      "aws", "s3api", "head-object",
      "--bucket", @bucket,
      "--key", key,
      "--region", @aws_region
    ]
    system(*cmd, out: File::NULL, err: File::NULL)
  end

  def fetch_heartbeat(instance_key)
    config = instance_upload_config(instance_key)
    return nil unless config && config[:heartbeat]

    key = config[:heartbeat][:key]
    cmd = ["aws", "s3", "cp", "s3://#{@bucket}/#{key}", "-", "--region", @aws_region]
    stdout, status = Open3.capture2(*cmd)
    return nil unless status.success?
    JSON.parse(stdout) rescue nil
  end

  def update_heartbeat_status(instance_key)
    data = fetch_heartbeat(instance_key)
    return unless data

    @status_mutex.synchronize do
      @instance_status[instance_key] ||= { status: "pending" }
      @instance_status[instance_key][:heartbeat_at] = data["timestamp"] || Time.now.utc.iso8601
      @instance_status[instance_key][:heartbeat_stage] = data["stage"] if data["stage"]
    end
  end

  def download_and_extract(instance_key, key)
    dest_dir = File.join(@results_path, sanitize_instance_key(instance_key))
    FileUtils.mkdir_p(dest_dir)
    tar_path = File.join(dest_dir, "result.tar.gz")
    return false unless system("aws", "s3", "cp", "s3://#{@bucket}/#{key}", tar_path, "--region", @aws_region)
    return false unless system("tar", "xzf", tar_path, "-C", dest_dir)
    true
  end

  def download_error(instance_key, key)
    dest_dir = File.join(@results_path, sanitize_instance_key(instance_key))
    FileUtils.mkdir_p(dest_dir)
    tar_path = File.join(dest_dir, "error.tar.gz")
    return false unless system("aws", "s3", "cp", "s3://#{@bucket}/#{key}", tar_path, "--region", @aws_region)
    return false unless system("tar", "xzf", tar_path, "-C", dest_dir)
    true
  end

  def mark_success(instance_key)
    @status_mutex.synchronize do
      @successful_instances << instance_key
      @instance_status[instance_key] = { status: "completed" }
      write_status(phase: "running_benchmarks", successful: @successful_instances, failed: @failed_instances)
    end
  end

  def mark_failed(instance_key, reason)
    @status_mutex.synchronize do
      @failed_instances << instance_key unless @failed_instances.include?(instance_key)
      @instance_status[instance_key] = { status: "failed", progress: reason }
      write_status(phase: "running_benchmarks", successful: @successful_instances, failed: @failed_instances, reason: reason)
    end
  end

  def finalize_run
    if @failed_instances.empty?
      update_status(phase: "destroying", message: "All benchmarks succeeded")
      terraform_destroy
      update_status(phase: "complete", results_path: @results_path, successful: @successful_instances)
    else
      update_status(
        phase: "failed",
        results_path: @results_path,
        failed: @failed_instances,
        successful: @successful_instances,
        run_id: @run_id
      )
      terraform_destroy
    end
  end

  def cleanup_temp_files
    FileUtils.rm_f(SKIP_TYPES_FILE)
    FileUtils.rm_f(UPLOAD_CONFIG_FILE)
  end

  def sanitize_instance_key(instance_key)
    instance_key.tr("._", "-").gsub(/[^A-Za-z0-9-]/, "-")
  end

  def update_status(data)
    @status_mutex.synchronize { write_status(data) }
  end

  def write_status(data)
    status = data.merge(updated_at: Time.now.iso8601)
    status[:instance_status] = @instance_status unless @instance_status.empty?
    tmp_file = "#{STATUS_FILE}.tmp"
    File.write(tmp_file, JSON.pretty_generate(status))
    File.rename(tmp_file, STATUS_FILE)
  end
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: bench.rb [options]"
  opts.on("--results-folder FOLDER", "Use existing results folder instead of creating new one") do |folder|
    options[:results_folder] = folder
  end
  opts.on("--replicas N", Integer, "Override replica count for all providers") do |n|
    options[:replicas] = n
  end
  opts.on("--aws-replicas N", Integer, "Override AWS replica count") do |n|
    options[:aws_replicas] = n
  end
  opts.on("--azure-replicas N", Integer, "Override Azure replica count") do |n|
    options[:azure_replicas] = n
  end
end.parse!

BenchmarkOrchestrator.new(**options).run
