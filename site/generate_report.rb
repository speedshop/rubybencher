#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'erb'
require 'set'

RESULTS_BASE = File.expand_path('../results', __dir__)
# Use the most recent results directory
RESULTS_DIR = Dir.glob(File.join(RESULTS_BASE, '*')).select { |f| File.directory?(f) }.max_by { |f| File.mtime(f) }
OUTPUT_DIR = File.expand_path('public', __dir__)
OUTPUT_FILE = File.join(OUTPUT_DIR, 'index.html')
TEMPLATE_FILE = File.expand_path('templates/report.html.erb', __dir__)
METADATA_FILE = 'metadata.json'

def load_instance_metadata(dir)
  path = File.join(dir, METADATA_FILE)
  return {} unless File.exist?(path)

  JSON.parse(File.read(path), symbolize_names: true)
rescue JSON::ParserError
  {}
end

def base_instance_name(name, metadata = {})
  return metadata[:instance_type] if metadata[:instance_type]

  name.sub(/-[^-]+$/, '')
end

def display_instance_name(base_name, metadata = {})
  label = base_name.to_s.gsub(/[_.]/, '-')
  provider = metadata[:provider]
  provider ? "#{provider}-#{label}" : label
end

def parse_benchmark_file(file_path)
  content = File.read(file_path)
  benchmarks = {}

  # Find Ruby version and architecture
  version_match = content.match(/ruby (\d+\.\d+\.\d+) .* \[(\w+-linux)\]/)
  ruby_version = version_match ? version_match[1] : 'unknown'
  architecture = version_match ? version_match[2] : 'unknown'

  lines = content.lines
  current_benchmark = nil
  current_iterations = []
  seen_benchmarks = Set.new

  lines.each do |line|
    # Match benchmark start
    if match = line.match(/^Running benchmark "([^"]+)" \((\d+)\/\d+\)/)
      benchmark_name = match[1]
      benchmark_num = match[2].to_i

      # Only process first run (stop if we see benchmark 1 again)
      if benchmark_num == 1 && seen_benchmarks.include?(benchmark_name)
        break
      end

      seen_benchmarks.add(benchmark_name)
      current_benchmark = benchmark_name
      current_iterations = []
    end

    # Match iteration line (e.g., " #1: 3355ms" or "#10:  267ms")
    if match = line.match(/^\s*#(\d+):\s*(\d+)ms/)
      current_iterations << match[2].to_i
    end

    # Match average line to determine non-warmup count
    if match = line.match(/^Average of last (\d+), non-warmup iters: (\d+)ms/)
      non_warmup_count = match[1].to_i
      average = match[2].to_i

      if current_benchmark && current_iterations.any?
        # Take the last N iterations as non-warmup
        non_warmup_iters = current_iterations.last(non_warmup_count)
        benchmarks[current_benchmark] = {
          iterations: non_warmup_iters,
          average: average
        }
      end
      current_benchmark = nil
      current_iterations = []
    end
  end

  { benchmarks: benchmarks, architecture: architecture, ruby_version: ruby_version }
end

def remap_instances(data, metadata = {})
  remapped = {}

  data.each do |instance, inst_data|
    meta = metadata[instance] || {}
    base_name = base_instance_name(instance, meta)
    new_name = display_instance_name(base_name, meta)
    remapped[new_name] ||= {
      benchmarks: {},
      architecture: inst_data[:architecture],
      ruby_version: inst_data[:ruby_version]
    }

    inst_data[:benchmarks].each do |bench_name, bench_data|
      dest = remapped[new_name][:benchmarks][bench_name]
      if dest
        dest[:iterations].concat(bench_data[:iterations])
      else
        dest = {
          iterations: bench_data[:iterations].dup,
          average: bench_data[:average]
        }
        remapped[new_name][:benchmarks][bench_name] = dest
      end
    end
  end

  # Recalculate averages after merging
  remapped.each_value do |inst_data|
    inst_data[:benchmarks].each_value do |bench_data|
      iters = bench_data[:iterations]
      bench_data[:average] = (iters.sum.to_f / iters.size).round
    end
  end

  remapped
end

def generate_html(data, run_id)
  all_benchmarks = data.values.flat_map { |d| d[:benchmarks].keys }.uniq.sort
  ruby_version = data.values.first[:ruby_version]

  # Parse run_id (e.g., "20251128-143326") into formatted date
  run_date = if run_id =~ /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/
    Time.new($1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, $6.to_i).strftime("%B %d, %Y at %H:%M UTC")
  else
    run_id
  end

  # Sort instances by total benchmark time (fastest first)
  instance_names = data.keys.sort_by do |instance|
    data[instance][:benchmarks].values.sum { |b| b[:average] }
  end

  # Build iteration data for D3
  # Sample up to max_per_instance points per benchmark/instance combo for even representation
  max_per_instance = 50

  iteration_data = []
  all_benchmarks.each do |benchmark|
    instance_names.each do |instance|
      bench_data = data[instance][:benchmarks][benchmark]
      next unless bench_data

      iters = bench_data[:iterations]
      # Sample evenly up to max_per_instance
      sample_count = [iters.size, max_per_instance].min
      step = iters.size.to_f / sample_count
      sampled = sample_count.times.map { |i| iters[(i * step).to_i] }

      sampled.each do |time|
        iteration_data << {
          benchmark: benchmark,
          instance: instance,
          time: time
        }
      end
    end
  end

  # Build summary table data with 95% CI
  table_data = all_benchmarks.map do |benchmark|
    row = { name: benchmark }
    instance_names.each do |instance|
      bench_data = data[instance][:benchmarks][benchmark]
      if bench_data
        row[instance] = bench_data[:average]
        # Calculate 95% CI
        iters = bench_data[:iterations]
        n = iters.size
        if n > 1
          mean = iters.sum.to_f / n
          variance = iters.map { |x| (x - mean) ** 2 }.sum / (n - 1)
          std_dev = Math.sqrt(variance)
          ci_95 = 1.96 * (std_dev / Math.sqrt(n))
          ci_percent = ((ci_95 / mean) * 100).round(1)
          row[instance.to_s + "_ci"] = ci_percent
        else
          row[instance.to_s + "_ci"] = 0
        end
      else
        row[instance] = nil
        row[instance.to_s + "_ci"] = nil
      end
    end
    row
  end

  # Calculate relative performance
  table_data.each do |row|
    times = instance_names.map { |i| row[i] }.compact
    next if times.empty?
    min_time = times.min

    instance_names.each do |instance|
      if row[instance]
        row[instance.to_s + "_relative"] = ((row[instance].to_f / min_time - 1) * 100).round(1)
      end
    end
  end

  # Summary stats
  summary = {}
  instance_names.each do |instance|
    times = table_data.map { |row| row[instance] }.compact
    summary[instance] = {
      total_time: times.sum,
      benchmark_count: times.size,
      architecture: data[instance][:architecture]
    }
  end

  fastest_total = summary.values.map { |s| s[:total_time] }.min
  summary.each do |instance, stats|
    stats[:relative_to_fastest] = ((stats[:total_time].to_f / fastest_total - 1) * 100).round(1)
  end

  # Create "all" row for totals
  all_row = { name: 'all', is_all: true }
  instance_names.each do |instance|
    all_row[instance] = summary[instance][:total_time]
    all_row[instance.to_s + "_ci"] = nil  # No CI for totals
    all_row[instance.to_s + "_relative"] = summary[instance][:relative_to_fastest]
  end

  template = File.read(TEMPLATE_FILE)
  [ERB.new(template).result(binding), iteration_data]
end

# Main
require 'fileutils'

abort "No results directory found in #{RESULTS_BASE}" unless RESULTS_DIR
puts "Using results from: #{RESULTS_DIR}"
puts "Parsing benchmark results..."

FileUtils.mkdir_p(OUTPUT_DIR)

# Copy static assets to public
static_dir = File.expand_path('static', __dir__)
FileUtils.cp_r(Dir.glob(File.join(static_dir, '*')), OUTPUT_DIR)

# Results are expected at results/{run_id}/{instance-type}/output.txt
# Instance names may have replica suffixes (e.g., c6g-medium-1, c6g-medium-2)
# Combine replicas into a single instance type
data = {}
instance_metadata = {}

instance_dirs = Dir.glob(File.join(RESULTS_DIR, '*')).select { |f| File.directory?(f) }

instance_dirs.each do |dir|
  raw_instance_name = File.basename(dir)
  output_file = File.join(dir, 'output.txt')
  next unless File.exist?(output_file)

  instance_name = raw_instance_name

  puts "  Parsing #{instance_name}..."
  run_data = parse_benchmark_file(output_file)
  meta = load_instance_metadata(dir)
  instance_metadata[instance_name] = meta unless meta.empty?

  data[instance_name] = run_data
end

# Recalculate averages after merging all replicas
data.each do |instance_name, instance_data|
  instance_data[:benchmarks].each do |bench_name, bench_data|
    iters = bench_data[:iterations]
    bench_data[:average] = (iters.sum.to_f / iters.size).round
  end
  total_iters = instance_data[:benchmarks].values.sum { |b| b[:iterations].size }
  puts "  #{instance_name}: #{instance_data[:benchmarks].size} benchmarks, #{total_iters} total iterations"
end

data = remap_instances(data, instance_metadata)

puts "\nGenerating HTML report..."
run_id = File.basename(RESULTS_DIR)
html, iteration_data = generate_html(data, run_id)
File.write(OUTPUT_FILE, html)

# Write iteration data to separate JSON file
data_json_file = File.join(OUTPUT_DIR, 'data.json')
File.write(data_json_file, JSON.generate(iteration_data))
puts "Data file generated: #{data_json_file} (#{File.size(data_json_file)} bytes)"

puts "Report generated: #{OUTPUT_FILE}"
