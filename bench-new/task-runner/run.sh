#!/usr/bin/env bash
set -euo pipefail

# Task Runner - Main Entry Point
# Polls orchestrator, claims tasks, runs benchmarks, reports results
# This script runs a single worker. To run multiple workers, start multiple containers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if --debug flag is present in arguments
DEBUG_MODE=false
for arg in "$@"; do
    if [[ "$arg" == "--debug" ]]; then
        DEBUG_MODE=true
        break
    fi
done

if [[ "$DEBUG_MODE" == "true" ]]; then
    # Create a log file to capture the full run output
    LOG_FILE="/tmp/task-runner-full-$(date +%Y%m%d-%H%M%S)-$$.log"
    echo "[RUN.SH] Debug mode enabled, capturing full output to: $LOG_FILE"

    # Use exec with process substitution to capture all output while still displaying it
    exec > >(tee -a "$LOG_FILE") 2>&1

    # Pass log file path to Ruby script
    exec ruby "$SCRIPT_DIR/lib/ruby/main.rb" --script-dir "$SCRIPT_DIR" --log-file "$LOG_FILE" "$@"
else
    # Normal mode - no logging
    exec ruby "$SCRIPT_DIR/lib/ruby/main.rb" --script-dir "$SCRIPT_DIR" "$@"
fi
