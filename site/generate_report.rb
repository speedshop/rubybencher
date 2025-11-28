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
    if match = line.match(/^Running benchmark "([^"]+)" \((\d+)\/67\)/)
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

def generate_html(data)
  all_benchmarks = data.values.flat_map { |d| d[:benchmarks].keys }.uniq.sort
  instance_names = data.keys.sort
  ruby_version = data.values.first[:ruby_version]

  # Build iteration data for D3 (sample to max 15 per instance per benchmark)
  max_samples = 15
  iteration_data = []
  all_benchmarks.each do |benchmark|
    instance_names.each do |instance|
      bench_data = data[instance][:benchmarks][benchmark]
      next unless bench_data

      iters = bench_data[:iterations]
      # Sample evenly if too many iterations
      sampled = if iters.size > max_samples
        step = iters.size.to_f / max_samples
        max_samples.times.map { |i| iters[(i * step).to_i] }
      else
        iters
      end

      sampled.each_with_index do |time, idx|
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
  ERB.new(template).result(binding)
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

instance_dirs = Dir.glob(File.join(RESULTS_DIR, '*')).select { |f| File.directory?(f) }
data = {}

instance_dirs.each do |dir|
  instance_name = File.basename(dir)
  output_file = File.join(dir, 'output.txt')
  next unless File.exist?(output_file)

  puts "  Parsing #{instance_name}..."
  data[instance_name] = parse_benchmark_file(output_file)

  total_iters = data[instance_name][:benchmarks].values.sum { |b| b[:iterations].size }
  puts "    Found #{data[instance_name][:benchmarks].size} benchmarks, #{total_iters} iterations"
end

puts "\nGenerating HTML report..."
html = generate_html(data)
File.write(OUTPUT_FILE, html)

puts "Report generated: #{OUTPUT_FILE}"
