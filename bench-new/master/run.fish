#!/usr/bin/env fish
# Master Script - Ruby Cross Cloud Benchmark Runner
# Orchestrates infrastructure standup, benchmark execution, and result collection

set -l script_path (status --current-filename)
set -g SCRIPT_DIR (cd (dirname $script_path); pwd -P)
set -g BENCH_DIR (cd "$SCRIPT_DIR/.."; pwd -P)
set -g REPO_ROOT (cd "$BENCH_DIR/.."; pwd -P)
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
source "$LIB_DIR/providers/common.fish"
source "$LIB_DIR/providers/aws.fish"
source "$LIB_DIR/providers/azure.fish"
source "$LIB_DIR/providers/local.fish"
source "$LIB_DIR/providers/registry.fish"
source "$LIB_DIR/run_flow.fish"
source "$LIB_DIR/main.fish"

main $argv
