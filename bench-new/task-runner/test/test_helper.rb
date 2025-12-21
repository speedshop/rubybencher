# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"

$LOAD_PATH.unshift File.expand_path("../lib/ruby", __dir__)

require "api_client"
require "benchmark_runner"
require "heartbeat"
require "packager"
require "logger"
require "worker"
