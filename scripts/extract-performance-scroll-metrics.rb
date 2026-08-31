#!/usr/bin/ruby
# frozen_string_literal: true

require 'json'

if ARGV.first == '--mark-top-level-unbaselined'
  _, performance_report_path, scroll_report_path, benchmark_session = ARGV
  abort 'usage: extract-performance-scroll-metrics.rb --mark-top-level-unbaselined <performance-report> <scroll-report> <benchmark-session>' unless
    [performance_report_path, scroll_report_path, benchmark_session].all? { |value| value && !value.empty? }

  scroll_report = JSON.parse(File.read(scroll_report_path))
  abort 'scroll sidecar must be schema version 1' unless scroll_report['schemaVersion'] == 1
  abort 'scroll sidecar has an unexpected status' unless scroll_report['status'] == 'measured-unbaselined'
  abort 'scroll sidecar has a stale benchmark session' unless scroll_report['benchmarkSession'] == benchmark_session
  abort 'scroll sidecar has no reduced system metrics' unless scroll_report['systemMetrics'].is_a?(Array) && !scroll_report['systemMetrics'].empty?

  performance_report = JSON.parse(File.read(performance_report_path))
  # Preserve an actual benchmark failure. A database-only pass is not enough
  # to make a run green once it also includes unthresholded scroll/hitch data.
  if performance_report['status'] == 'passed'
    performance_report['status'] = 'measured-unbaselined'
    temporary_path = "#{performance_report_path}.tmp-#{Process.pid}"
    begin
      File.write(temporary_path, JSON.generate(performance_report))
      File.rename(temporary_path, performance_report_path)
    ensure
      File.delete(temporary_path) if File.exist?(temporary_path)
    end
  end
  exit 0
end

if ARGV.first == '--require-top-level-status'
  _, performance_report_path, expected_status = ARGV
  abort 'usage: extract-performance-scroll-metrics.rb --require-top-level-status <performance-report> <expected-status>' unless
    [performance_report_path, expected_status].all? { |value| value && !value.empty? }

  performance_report = JSON.parse(File.read(performance_report_path))
  abort "performance report top-level status is not #{expected_status}" unless performance_report['status'] == expected_status
  exit 0
end

scroll_report_path, metrics_path, benchmark_session = ARGV
abort 'usage: extract-performance-scroll-metrics.rb <scroll-report> <xcresult-metrics> <benchmark-session>' unless
  [scroll_report_path, metrics_path, benchmark_session].all? { |value| value && !value.empty? }

expected_identifiers = [
  'com.apple.dt.XCTOSSignpostMetric.scrollingAndDeceleration',
  'com.apple.dt.XCTHitchMetric'
].freeze
expected_sample_count = 11

def nearest_rank(sorted, fraction)
  sorted[[(fraction * sorted.length).ceil, 1].max - 1]
end

def collect_metrics(value, output)
  case value
  when Hash
    metrics = value['metrics']
    output.concat(metrics) if metrics.is_a?(Array)
    value.each_value { |child| collect_metrics(child, output) }
  when Array
    value.each { |child| collect_metrics(child, output) }
  end
end

report = JSON.parse(File.read(scroll_report_path))
abort 'scroll sidecar must be schema version 1' unless report['schemaVersion'] == 1
abort 'scroll sidecar has an unexpected status' unless report['status'] == 'measured-unbaselined'
abort 'scroll sidecar has a stale benchmark session' unless report['benchmarkSession'] == benchmark_session
abort 'scroll sidecar must not pre-populate system metrics' unless report['systemMetrics'] == []

all_metrics = []
collect_metrics(JSON.parse(File.read(metrics_path)), all_metrics)
selected = expected_identifiers.map do |identifier|
  matches = all_metrics.select { |metric| metric['identifier'] == identifier }
  abort "missing or ambiguous XCTest metric #{identifier}" unless matches.length == 1

  metric = matches.first
  unit = metric['unitOfMeasurement']
  samples = metric['measurements']
  abort "XCTest metric #{identifier} has no unit" unless unit.is_a?(String) && !unit.empty?
  abort "XCTest metric #{identifier} has invalid samples" unless samples.is_a?(Array) && samples.length == expected_sample_count
  samples = samples.map { |sample| Float(sample) }
  abort "XCTest metric #{identifier} has non-finite samples" unless samples.all?(&:finite?) && samples.all? { |sample| sample >= 0 }
  sorted = samples.sort
  {
    'identifier' => identifier,
    'unit' => unit,
    'count' => samples.length,
    'minimum' => sorted.first,
    'median' => nearest_rank(sorted, 0.5),
    'p95' => nearest_rank(sorted, 0.95),
    'maximum' => sorted.last
  }
end

report['systemMetrics'] = selected
File.write(scroll_report_path, JSON.generate(report))
