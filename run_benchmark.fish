#!/usr/bin/env fish

set SCRIPT_DIR (dirname (status filename))
set BENCH_SCRIPT "$SCRIPT_DIR/bench/bench.rb"
set STATUS_FILE "$SCRIPT_DIR/status.json"
set LOG_FILE "$SCRIPT_DIR/bench.log"
set -g NONINTERACTIVE false

# Parse global flags
function parse_flags
    set -g ARGS
    for arg in $argv
        switch $arg
            case -y --yes
                set -g NONINTERACTIVE true
            case '*'
                set -g ARGS $ARGS $arg
        end
    end
end

# Confirm helper - auto-accepts in non-interactive mode
function confirm
    if test "$NONINTERACTIVE" = "true"
        return 0
    end
    gum confirm $argv
end

# Spin helper - skips spinner in non-interactive mode
function spin
    if test "$NONINTERACTIVE" = "true"
        # Find the command after "--"
        set -l cmd_started false
        set -l cmd
        for arg in $argv
            if test "$cmd_started" = "true"
                set cmd $cmd $arg
            else if test "$arg" = "--"
                set cmd_started true
            end
        end
        eval $cmd
    else
        gum spin $argv
    end
end

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
        case starting
            echo "⏳"
        case running
            echo "🔄"
        case completed
            echo "✅"
        case terminated
            echo "🏁"
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
    set updated_at (jq -r '.updated_at // ""' $STATUS_FILE)

    # Header
    set header (gum style --bold --foreground 212 "Railsbencher")

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

    # Instance status - group by instance type, compact horizontal layout
    set instances_json (jq -r '.instance_status // {}' $STATUS_FILE)
    set instance_types_list
    set instance_type_data
    if test "$instances_json" != "{}" -a "$instances_json" != "null"
        # Get unique instance types and build compact display
        set instance_keys (echo $instances_json | jq -r 'keys[]' 2>/dev/null | sort)
        set current_type ""
        set type_replicas ""

        for instance_key in $instance_keys
            set inst_type (echo $instance_key | sed 's/-[0-9]*$//')
            set inst_status (echo $instances_json | jq -r ".[\"$instance_key\"].status // \"unknown\"")
            set progress_val (echo $instances_json | jq -r ".[\"$instance_key\"].progress // empty")
            set icon (instance_status_icon $inst_status)

            # Build replica display (icon + progress if running)
            if test "$inst_status" = "running" -a -n "$progress_val" -a "$progress_val" != "null"
                set replica_display "$icon ""$progress_val"
            else
                set replica_display "$icon"
            end

            if test "$inst_type" != "$current_type"
                # Save previous type if exists
                if test -n "$current_type"
                    set instance_types_list $instance_types_list "$current_type"
                    set instance_type_data $instance_type_data "$type_replicas"
                end
                set current_type $inst_type
                set type_replicas $replica_display
            else
                set type_replicas "$type_replicas $replica_display"
            end
        end
        # Save last type
        if test -n "$current_type"
            set instance_types_list $instance_types_list "$current_type"
            set instance_type_data $instance_type_data "$type_replicas"
        end
    end

    # Build output
    clear
    echo
    echo $header
    echo
    echo $phase_style

    if test (count $instance_types_list) -gt 0
        echo
        gum style --foreground 245 "Instances:"

        # Calculate column width based on longest type name + replicas
        set max_width 0
        for i in (seq (count $instance_types_list))
            set type_name $instance_types_list[$i]
            set replicas $instance_type_data[$i]
            set entry_len (string length "$type_name $replicas")
            if test $entry_len -gt $max_width
                set max_width $entry_len
            end
        end
        set col_width (math $max_width + 4)

        # Get terminal width, default to 80
        set term_width (tput cols 2>/dev/null || echo 80)
        set num_cols (math "floor($term_width / $col_width)")
        if test $num_cols -lt 1
            set num_cols 1
        end

        # Display in columns
        set total_types (count $instance_types_list)
        set i 1
        while test $i -le $total_types
            set line ""
            for col in (seq $num_cols)
                if test $i -le $total_types
                    set type_name $instance_types_list[$i]
                    set replicas $instance_type_data[$i]
                    set entry (printf "%-"$col_width"s" "$type_name $replicas")
                    set line "$line$entry"
                    set i (math $i + 1)
                end
            end
            echo "  $line"
        end
    end

    # Show timing with seconds ago
    if test -n "$updated_at" -a "$updated_at" != "null"
        set updated_epoch (date -j -f "%Y-%m-%dT%H:%M:%S" (echo $updated_at | cut -d+ -f1) "+%s" 2>/dev/null)
        set now_epoch (date "+%s")
        if test -n "$updated_epoch"
            set secs_ago (math $now_epoch - $updated_epoch)
            echo
            gum style --foreground 241 --italic "Last change: $updated_at ($secs_ago sec ago)"
        else
            echo
            gum style --foreground 241 --italic "Last change: $updated_at"
        end
    end

    # Check for completion
    switch $phase
        case complete
            echo
            set results_path (jq -r '.results_path // ""' $STATUS_FILE)
            set successful_count (jq -r '.successful | length' $STATUS_FILE)
            gum style --foreground 82 "All $successful_count instances completed successfully!"
            if test -n "$results_path" -a "$results_path" != "null"
                gum style --foreground 245 "Results: $results_path"
            end
            return 0
        case failed
            echo
            set failed_count (jq -r '.failed | length' $STATUS_FILE)
            set successful_count (jq -r '.successful | length' $STATUS_FILE)
            gum style --foreground 196 "Benchmark failed: $failed_count instance(s) failed, $successful_count succeeded"
            return 2
    end

    return 1
end

function monitor_benchmark
    spin --spinner dot --title "Starting benchmark monitor..." -- sleep 1

    while true
        show_status
        set status_code $status

        if test $status_code -eq 0
            # Complete
            break
        else if test $status_code -eq 2
            # Failed (status file says failed)
            if test "$NONINTERACTIVE" != "true"
                if confirm "View log file?"
                    less $LOG_FILE
                end
            end
            break
        end

        # Check if process crashed (not running but status isn't complete/failed)
        # Only report crash if we have a valid status file with a non-starting phase
        # This prevents false positives when monitoring is started before/separately from the benchmark
        if not pgrep -qf "ruby.*bench.rb"
            set phase (jq -r '.phase // "unknown"' $STATUS_FILE 2>/dev/null)
            # Only consider it crashed if we're in a mid-run phase (not starting/unknown/complete/failed)
            # Starting phases: starting, starting_run
            # Terminal phases: complete, failed
            # Mid-run phases: everything else (terraform_apply, instances_ready, etc.)
            switch $phase
                case complete failed starting starting_run unknown ""
                    # Not a crash - either terminal, just starting, or no status yet
                case '*'
                    # Mid-run phase with no process = crash
                    echo
                    gum style --foreground 196 --bold "Benchmark process crashed!"
                    echo
                    gum style --foreground 245 "Last lines of log:"
                    echo
                    tail -20 $LOG_FILE 2>/dev/null | grep -E "(Error|error|failed|Failed|denied|Denied)" | tail -5
                    echo
                    gum style --foreground 245 "Run './run_benchmark.fish nuke' to clean up, then retry."
                    if test "$NONINTERACTIVE" != "true"
                        if confirm "View full log?"
                            less $LOG_FILE
                        end
                    end
                    break
            end
        end

        sleep 2
    end
end

function select_results_folder
    set results_dir "$SCRIPT_DIR/results"
    set new_folder_name (date "+%Y%m%d-%H%M%S")

    # Get existing folders (excluding hidden files and non-directories)
    set existing_folders (ls -1d $results_dir/*/ 2>/dev/null | xargs -n1 basename | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r)

    # Build choices list
    set choices "New folder ($new_folder_name)"
    for folder in $existing_folders
        set choices $choices $folder
    end

    if test "$NONINTERACTIVE" = "true"
        # Non-interactive mode: always create new folder
        echo $new_folder_name
        return
    end

    gum style --foreground 245 "Select results folder:"
    set choice (printf '%s\n' $choices | gum choose)

    if test -z "$choice"
        # User cancelled
        echo ""
        return
    end

    if string match -q "New folder*" "$choice"
        echo $new_folder_name
    else
        # Warn about overwriting
        set folder_path "$results_dir/$choice"
        set file_count (find $folder_path -type f 2>/dev/null | wc -l | string trim)
        if test "$file_count" -gt 0
            echo
            gum style --foreground 214 "Warning: $choice contains $file_count file(s)"
            if not confirm --default=false "Overwrite existing results?"
                echo ""
                return
            end
        end
        echo $choice
    end
end

function start_benchmark
    gum style --bold --foreground 212 "Railsbencher"
    echo

    if not test -f $BENCH_SCRIPT
        gum log --level error "Benchmark script not found: $BENCH_SCRIPT"
        exit 1
    end

    # Select results folder
    set results_folder (select_results_folder)
    if test -z "$results_folder"
        gum log --level info "Cancelled"
        exit 0
    end

    echo

    # Confirm start (skip in non-interactive mode)
    if test "$NONINTERACTIVE" != "true"
        gum style --foreground 245 "This will create 12 EC2 instances (3 replicas x 4 types)"
        gum style --foreground 245 "and run the benchmark suite on each in parallel."
        gum style --foreground 245 "Results will be saved to: results/$results_folder"
        echo

        if not confirm "Start benchmark?"
            gum log --level info "Cancelled"
            exit 0
        end
    end

    echo
    gum log --level info "Starting benchmark in background..."

    # Start benchmark in background with results folder argument
    ruby $BENCH_SCRIPT --results-folder "$results_folder" > $LOG_FILE 2>&1 &
    set bench_pid $last_pid

    gum log --level info "Benchmark started (PID: $bench_pid)"
    gum log --level info "Log file: $LOG_FILE"
    echo

    sleep 2
    monitor_benchmark
end

function nuke_aws_resources
    gum style --bold --foreground 196 "☢️  NUKE AWS RESOURCES"
    echo
    gum style --foreground 245 "This will find and delete ALL ruby-bench-* resources in AWS,"
    gum style --foreground 245 "regardless of Terraform state."
    echo

    set region "us-east-1"
    set terraform_dir "$SCRIPT_DIR/bench/terraform"

    # Try terraform destroy first if state exists
    if test -f "$terraform_dir/terraform.tfstate"
        gum log --level info "Found Terraform state, running terraform destroy..."
        spin --spinner dot --title "Running terraform destroy..." -- sh -c "cd $terraform_dir && terraform destroy -auto-approve > /dev/null 2>&1"
        rm -f "$terraform_dir/terraform.tfstate" "$terraform_dir/terraform.tfstate.backup" "$terraform_dir/bench-key.pem" 2>/dev/null
        gum log --level info "Terraform destroy complete, scanning for orphaned resources..."
    end

    # Find instances
    spin --spinner dot --title "Finding EC2 instances..." -- sleep 1
    set instances (aws ec2 describe-instances \
        --region $region \
        --filters "Name=tag:Name,Values=ruby-bench-*" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null | string split -n \t)

    if test (count $instances) -gt 0
        gum log --level warn "Found "(count $instances)" instances: $instances"
    else
        set instances
        gum log --level info "No running instances found"
    end

    # Find VPC
    set vpc_id (aws ec2 describe-vpcs \
        --region $region \
        --filters "Name=tag:Name,Values=ruby-bench-vpc" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null)

    if test "$vpc_id" != "None" -a -n "$vpc_id"
        gum log --level warn "Found VPC: $vpc_id"
    else
        set vpc_id ""
        gum log --level info "No VPC found"
    end

    # Find key pair
    set key_exists "no"
    if aws ec2 describe-key-pairs --region $region --key-names ruby-bench >/dev/null 2>&1
        set key_exists "yes"
    end

    if test "$key_exists" = "yes"
        gum log --level warn "Found key pair: ruby-bench"
    else
        gum log --level info "No key pair found"
    end

    # Confirm
    if test (count $instances) -eq 0 -a -z "$vpc_id" -a "$key_exists" = "no"
        echo
        gum log --level info "No ruby-bench resources found. Nothing to delete."
        return 0
    end

    echo
    if not confirm --default=false "Delete all these resources?"
        gum log --level info "Cancelled"
        return 0
    end

    echo

    # Terminate instances
    if test (count $instances) -gt 0
        gum log --level info "Terminating instances..."
        aws ec2 terminate-instances --region $region --instance-ids $instances > /dev/null 2>&1

        spin --spinner dot --title "Waiting for instances to terminate..." -- \
            aws ec2 wait instance-terminated --region $region --instance-ids $instances 2>/dev/null
        gum log --level info "Instances terminated"
    end

    # Delete VPC resources (in dependency order)
    if test -n "$vpc_id"
        # Delete security groups (except default)
        set sgs (aws ec2 describe-security-groups \
            --region $region \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
            --output text 2>/dev/null | string split -n \t)
        for sg in $sgs
            gum log --level info "Deleting security group $sg..."
            aws ec2 delete-security-group --region $region --group-id $sg 2>/dev/null
        end

        # Delete subnets
        set subnets (aws ec2 describe-subnets \
            --region $region \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'Subnets[].SubnetId' \
            --output text 2>/dev/null | string split -n \t)
        for subnet in $subnets
            gum log --level info "Deleting subnet $subnet..."
            aws ec2 delete-subnet --region $region --subnet-id $subnet 2>/dev/null
        end

        # Delete route table associations and route tables (except main)
        set rts (aws ec2 describe-route-tables \
            --region $region \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
            --output text 2>/dev/null | string split -n \t)
        for rt in $rts
            # Delete associations first
            set assocs (aws ec2 describe-route-tables \
                --region $region \
                --route-table-ids $rt \
                --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
                --output text 2>/dev/null | string split -n \t)
            for assoc in $assocs
                aws ec2 disassociate-route-table --region $region --association-id $assoc 2>/dev/null
            end
            gum log --level info "Deleting route table $rt..."
            aws ec2 delete-route-table --region $region --route-table-id $rt 2>/dev/null
        end

        # Detach and delete internet gateway
        set igws (aws ec2 describe-internet-gateways \
            --region $region \
            --filters "Name=attachment.vpc-id,Values=$vpc_id" \
            --query 'InternetGateways[].InternetGatewayId' \
            --output text 2>/dev/null | string split -n \t)
        for igw in $igws
            gum log --level info "Detaching and deleting internet gateway $igw..."
            aws ec2 detach-internet-gateway --region $region --internet-gateway-id $igw --vpc-id $vpc_id 2>/dev/null
            aws ec2 delete-internet-gateway --region $region --internet-gateway-id $igw 2>/dev/null
        end

        # Delete VPC
        gum log --level info "Deleting VPC $vpc_id..."
        aws ec2 delete-vpc --region $region --vpc-id $vpc_id 2>/dev/null
    end

    # Delete key pair
    if test "$key_exists" = "yes"
        gum log --level info "Deleting key pair..."
        aws ec2 delete-key-pair --region $region --key-name ruby-bench 2>/dev/null
    end

    # Final cleanup of local files
    rm -f "$terraform_dir/terraform.tfstate" "$terraform_dir/terraform.tfstate.backup" "$terraform_dir/bench-key.pem" 2>/dev/null

    echo
    gum log --level info "Done! All ruby-bench resources have been deleted."
end

function stop_benchmark
    gum style --bold --foreground 212 "Railsbencher"
    echo

    # Find running bench.rb process
    set bench_pids (pgrep -f "ruby.*bench.rb" 2>/dev/null)

    if test -z "$bench_pids"
        gum log --level warn "No benchmark process found running"
    else
        gum log --level info "Found benchmark process(es): $bench_pids"
        if confirm "Kill benchmark process(es)?"
            for pid in $bench_pids
                kill $pid 2>/dev/null && gum log --level info "Killed process $pid"
            end
        end
    end

    # Check for Terraform infrastructure
    set terraform_dir "$SCRIPT_DIR/bench/terraform"
    if test -f "$terraform_dir/terraform.tfstate"
        set instance_count (cd $terraform_dir && terraform state list 2>/dev/null | grep -c "aws_instance" || echo "0")
        if test "$instance_count" -gt 0
            echo
            gum log --level warn "Found $instance_count EC2 instance(s) still running"
            if confirm "Destroy Terraform infrastructure?"
                spin --spinner dot --title "Destroying infrastructure..." -- sh -c "cd $terraform_dir && terraform destroy -auto-approve > /dev/null 2>&1"
                if test $status -eq 0
                    gum log --level info "Infrastructure destroyed"
                else
                    gum log --level error "Failed to destroy infrastructure"
                    gum log --level info "Run manually: cd $terraform_dir && terraform destroy"
                end
            end
        else
            gum log --level info "No EC2 instances running"
        end
    end

    echo
    gum log --level info "Done"
end

function show_help
    gum style --bold --foreground 212 "Railsbencher"
    echo
    gum style "Usage: run_benchmark.fish [-y|--yes] [command]"
    echo
    gum style --bold "Commands:"
    echo "  start    Start the benchmark and monitor progress"
    echo "  monitor  Monitor an already-running benchmark"
    echo "  stop     Stop running benchmark and destroy infrastructure"
    echo "  nuke     Delete ALL ruby-bench AWS resources (failsafe cleanup)"
    echo "  status   Show current status once and exit"
    echo "  help     Show this help message"
    echo
    gum style --bold "Options:"
    echo "  -y, --yes  Non-interactive mode (auto-confirm all prompts)"
    echo
    gum style --bold "Examples:"
    echo "  ./run_benchmark.fish start"
    echo "  ./run_benchmark.fish -y start"
    echo "  ./run_benchmark.fish --yes nuke"
end

# Main
parse_flags $argv
set cmd $ARGS[1]

switch $cmd
    case start
        start_benchmark
    case monitor
        monitor_benchmark
    case stop
        stop_benchmark
    case nuke
        nuke_aws_resources
    case status
        show_status
    case help --help -h
        show_help
    case ''
        if test "$NONINTERACTIVE" = "true"
            gum log --level error "Command required in non-interactive mode"
            show_help
            exit 1
        end
        # Default: ask what to do
        set choice (gum choose "Start new benchmark" "Monitor running benchmark" "Stop benchmark" "Nuke AWS resources" "Show status" "Help")
        switch $choice
            case "Start new benchmark"
                start_benchmark
            case "Monitor running benchmark"
                monitor_benchmark
            case "Stop benchmark"
                stop_benchmark
            case "Nuke AWS resources"
                nuke_aws_resources
            case "Show status"
                show_status
            case "Help"
                show_help
        end
    case '*'
        gum log --level error "Unknown command: $cmd"
        show_help
        exit 1
end
