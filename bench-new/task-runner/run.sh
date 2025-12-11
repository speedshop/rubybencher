#!/usr/bin/env bash
set -euo pipefail

# Task Runner - Main Entry Point
# Polls orchestrator, claims tasks, runs benchmarks, reports results
# This script runs a single worker. To run multiple workers, start multiple containers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pass all arguments to the Ruby worker
exec ruby "$SCRIPT_DIR/lib/ruby/main.rb" --script-dir "$SCRIPT_DIR" "$@"
