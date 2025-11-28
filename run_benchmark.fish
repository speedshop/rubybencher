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
        case starting
            echo "⏳"
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
    set current_run (jq -r '.current_run // 0' $STATUS_FILE)
    set total_runs (jq -r '.total_runs // 3' $STATUS_FILE)
    set updated_at (jq -r '.updated_at // ""' $STATUS_FILE)

    # Header
    set header (gum style --bold --foreground 212 "Railsbencher")

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
            # Handle both old format (string) and new format (object with status/benchmark/progress)
            set status_raw (echo $instances_json | jq -r ".[\"$instance_type\"]")
            if echo $status_raw | jq -e 'type == "object"' >/dev/null 2>&1
                set inst_status (echo $instances_json | jq -r ".[\"$instance_type\"].status // \"unknown\"")
                set benchmark (echo $instances_json | jq -r ".[\"$instance_type\"].benchmark // empty")
                set progress (echo $instances_json | jq -r ".[\"$instance_type\"].progress // empty")
            else
                set inst_status $status_raw
                set benchmark ""
                set progress ""
            end
            set icon (instance_status_icon $inst_status)
            if test -n "$progress" -a "$progress" != "null"
                set instance_lines "$instance_lines\n  $icon $instance_type ($progress)"
            else
                set instance_lines "$instance_lines\n  $icon $instance_type"
            end
        end
    end

    # Build output
    clear
    echo
    echo $header
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
            # Failed (status file says failed)
            if gum confirm "View log file?"
                less $LOG_FILE
            end
            break
        end

        # Check if process crashed (not running but status isn't complete/failed)
        if not pgrep -qf "ruby.*bench/bench.rb"
            set phase (jq -r '.phase // "unknown"' $STATUS_FILE 2>/dev/null)
            if test "$phase" != "complete" -a "$phase" != "failed"
                echo
                gum style --foreground 196 --bold "Benchmark process crashed!"
                echo
                gum style --foreground 245 "Last lines of log:"
                echo
                tail -20 $LOG_FILE 2>/dev/null | grep -E "(Error|error|failed|Failed|denied|Denied)" | tail -5
                echo
                gum style --foreground 245 "Run './run_benchmark.fish nuke' to clean up, then retry."
                if gum confirm "View full log?"
                    less $LOG_FILE
                end
                break
            end
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
        gum spin --spinner dot --title "Running terraform destroy..." -- sh -c "cd $terraform_dir && terraform destroy -auto-approve > /dev/null 2>&1"
        rm -f "$terraform_dir/terraform.tfstate" "$terraform_dir/terraform.tfstate.backup" "$terraform_dir/bench-key.pem" 2>/dev/null
        gum log --level info "Terraform destroy complete, scanning for orphaned resources..."
    end

    # Find instances
    gum spin --spinner dot --title "Finding EC2 instances..." -- sleep 1
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
    if not gum confirm --default=false "Delete all these resources?"
        gum log --level info "Cancelled"
        return 0
    end

    echo

    # Terminate instances
    if test (count $instances) -gt 0
        gum log --level info "Terminating instances..."
        aws ec2 terminate-instances --region $region --instance-ids $instances > /dev/null 2>&1

        gum spin --spinner dot --title "Waiting for instances to terminate..." -- \
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
    set bench_pids (pgrep -f "ruby.*bench/bench.rb" 2>/dev/null)

    if test -z "$bench_pids"
        gum log --level warn "No benchmark process found running"
    else
        gum log --level info "Found benchmark process(es): $bench_pids"
        if gum confirm "Kill benchmark process(es)?"
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
            if gum confirm "Destroy Terraform infrastructure?"
                gum spin --spinner dot --title "Destroying infrastructure..." -- sh -c "cd $terraform_dir && terraform destroy -auto-approve > /dev/null 2>&1"
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
    gum style "Usage: run_benchmark.fish [command]"
    echo
    gum style --bold "Commands:"
    echo "  start    Start the benchmark and monitor progress"
    echo "  monitor  Monitor an already-running benchmark"
    echo "  stop     Stop running benchmark and destroy infrastructure"
    echo "  nuke     Delete ALL ruby-bench AWS resources (failsafe cleanup)"
    echo "  status   Show current status once and exit"
    echo "  help     Show this help message"
    echo
    gum style --bold "Examples:"
    echo "  ./run_benchmark.fish start"
    echo "  ./run_benchmark.fish monitor"
    echo "  ./run_benchmark.fish nuke"
end

# Main
switch $argv[1]
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
        gum log --level error "Unknown command: $argv[1]"
        show_help
        exit 1
end
