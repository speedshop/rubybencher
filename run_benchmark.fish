#!/usr/bin/env fish

set SCRIPT_DIR (dirname (status filename))
set BENCH_SCRIPT "$SCRIPT_DIR/bench/bench.rb"
set STATUS_FILE "$SCRIPT_DIR/status.json"
set LOG_FILE "$SCRIPT_DIR/bench.log"

function phase_to_description
    switch $argv[1]
        case starting
            echo "Initializing benchmark run"
        case starting_run
            echo "Starting run"
        case terraform_apply
            echo "Provisioning EC2 instances"
        case instances_ready
            echo "Instances ready"
        case waiting_for_ssh
            echo "Waiting for SSH connectivity"
        case ssh_ready
            echo "SSH connected"
        case waiting_for_docker_setup
            echo "Setting up Docker"
        case docker_ready
            echo "Docker ready"
        case running_benchmarks
            echo "Running benchmarks"
        case collecting_results
            echo "Collecting results"
        case destroying
            echo "Destroying infrastructure"
        case run_failed
            echo "Run failed"
        case complete
            echo "Complete"
        case failed
            echo "Failed"
        case '*'
            echo $argv[1]
    end
end

function instance_status_icon
    switch $argv[1]
        case running
            echo "🔄"
        case completed
            echo "✅"
        case failed
            echo "❌"
        case '*'
            echo "⏳"
    end
end

function show_status
    if not test -f $STATUS_FILE
        gum style --foreground 241 "Waiting for status..."
        return 1
    end

    set phase (jq -r '.phase // "unknown"' $STATUS_FILE)
    set run_id (jq -r '.run_id // "unknown"' $STATUS_FILE)
    set current_run (jq -r '.current_run // 0' $STATUS_FILE)
    set total_runs (jq -r '.total_runs // 3' $STATUS_FILE)
    set updated_at (jq -r '.updated_at // ""' $STATUS_FILE)

    # Header
    set header (gum style --bold --foreground 212 "Railsbencher")
    set run_info (gum style --foreground 245 "Run ID: $run_id")

    # Progress
    if test "$current_run" != "0" -a "$current_run" != "null"
        set progress_text "Run $current_run of $total_runs"
        set progress_bar ""
        for i in (seq 1 $total_runs)
            if test $i -lt $current_run
                set progress_bar "$progress_bar●"
            else if test $i -eq $current_run
                set progress_bar "$progress_bar◉"
            else
                set progress_bar "$progress_bar○"
            end
        end
        set progress (gum style --foreground 39 "$progress_bar  $progress_text")
    else
        set progress ""
    end

    # Phase
    set phase_desc (phase_to_description $phase)
    switch $phase
        case complete
            set phase_style (gum style --foreground 82 --bold "✓ $phase_desc")
        case failed run_failed
            set phase_style (gum style --foreground 196 --bold "✗ $phase_desc")
        case running_benchmarks
            set phase_style (gum style --foreground 220 "⚡ $phase_desc")
        case '*'
            set phase_style (gum style --foreground 245 "→ $phase_desc")
    end

    # Instance status
    set instances_json (jq -r '.instance_status // {}' $STATUS_FILE)
    set instance_lines ""
    if test "$instances_json" != "{}" -a "$instances_json" != "null"
        set instance_types (echo $instances_json | jq -r 'keys[]' 2>/dev/null)
        for instance_type in $instance_types
            set status (echo $instances_json | jq -r ".[\"$instance_type\"]")
            set icon (instance_status_icon $status)
            set instance_lines "$instance_lines\n  $icon $instance_type"
        end
    end

    # Build output
    clear
    echo
    echo $header
    echo $run_info
    if test -n "$progress"
        echo
        echo $progress
    end
    echo
    echo $phase_style

    if test -n "$instance_lines"
        echo
        gum style --foreground 245 "Instances:"
        echo -e $instance_lines
    end

    # Show timing
    if test -n "$updated_at" -a "$updated_at" != "null"
        echo
        gum style --foreground 241 --italic "Updated: $updated_at"
    end

    # Check for completion
    switch $phase
        case complete
            echo
            set results_path (jq -r '.results_path // ""' $STATUS_FILE)
            set successful_runs (jq -r '.successful_runs | length' $STATUS_FILE)
            gum style --foreground 82 "All $successful_runs runs completed successfully!"
            if test -n "$results_path" -a "$results_path" != "null"
                gum style --foreground 245 "Results: $results_path"
            end
            return 0
        case failed
            echo
            set failed_count (jq -r '.failed_runs | length' $STATUS_FILE)
            set successful_count (jq -r '.successful_runs | length' $STATUS_FILE)
            gum style --foreground 196 "Benchmark failed: $failed_count run(s) failed, $successful_count succeeded"
            return 2
    end

    return 1
end

function monitor_benchmark
    gum spin --spinner dot --title "Starting benchmark monitor..." -- sleep 1

    while true
        show_status
        set status_code $status

        if test $status_code -eq 0
            # Complete
            break
        else if test $status_code -eq 2
            # Failed
            if gum confirm "View log file?"
                less $LOG_FILE
            end
            break
        end

        sleep 2
    end
end

function start_benchmark
    gum style --bold --foreground 212 "Railsbencher"
    echo

    if not test -f $BENCH_SCRIPT
        gum log --level error "Benchmark script not found: $BENCH_SCRIPT"
        exit 1
    end

    # Confirm start
    set total_runs 3
    gum style --foreground 245 "This will run the benchmark suite $total_runs times,"
    gum style --foreground 245 "creating and destroying EC2 instances each time."
    echo

    if not gum confirm "Start benchmark?"
        gum log --level info "Cancelled"
        exit 0
    end

    echo
    gum log --level info "Starting benchmark in background..."

    # Start benchmark in background
    ruby $BENCH_SCRIPT > $LOG_FILE 2>&1 &
    set bench_pid $last_pid

    gum log --level info "Benchmark started (PID: $bench_pid)"
    gum log --level info "Log file: $LOG_FILE"
    echo

    sleep 2
    monitor_benchmark
end

function show_help
    gum style --bold --foreground 212 "Railsbencher"
    echo
    gum style "Usage: run_benchmark.fish [command]"
    echo
    gum style --bold "Commands:"
    echo "  start    Start the benchmark and monitor progress"
    echo "  monitor  Monitor an already-running benchmark"
    echo "  status   Show current status once and exit"
    echo "  help     Show this help message"
    echo
    gum style --bold "Examples:"
    echo "  ./run_benchmark.fish start"
    echo "  ./run_benchmark.fish monitor"
end

# Main
switch $argv[1]
    case start
        start_benchmark
    case monitor
        monitor_benchmark
    case status
        show_status
    case help --help -h
        show_help
    case ''
        # Default: ask what to do
        set choice (gum choose "Start new benchmark" "Monitor running benchmark" "Show status" "Help")
        switch $choice
            case "Start new benchmark"
                start_benchmark
            case "Monitor running benchmark"
                monitor_benchmark
            case "Show status"
                show_status
            case "Help"
                show_help
        end
    case '*'
        gum log --level error "Unknown command: $argv[1]"
        show_help
        exit 1
end
