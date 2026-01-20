#!/usr/bin/env fish
# Master Script - Ruby Cross Cloud Benchmark Runner
# Orchestrates infrastructure standup, benchmark execution, and result collection

set -g SCRIPT_DIR (dirname (status --current-filename))
set -g BENCH_DIR (dirname $SCRIPT_DIR)
set -g REPO_ROOT (dirname $BENCH_DIR)
set -g RESULTS_DIR "$REPO_ROOT/results"
set -g LIB_DIR "$SCRIPT_DIR/lib"

source "$LIB_DIR/logging.fish"
source "$LIB_DIR/defaults.fish"
source "$LIB_DIR/config.fish"
source "$LIB_DIR/utils.fish"
source "$LIB_DIR/status.fish"
source "$LIB_DIR/dependencies.fish"
source "$LIB_DIR/orchestrator.fish"
source "$LIB_DIR/infrastructure.fish"
source "$LIB_DIR/providers/aws.fish"
source "$LIB_DIR/providers/azure.fish"
source "$LIB_DIR/providers/local.fish"
source "$LIB_DIR/providers/registry.fish"
source "$LIB_DIR/run_flow.fish"
source "$LIB_DIR/main.fish"

main $argv
