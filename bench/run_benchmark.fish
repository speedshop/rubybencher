#!/usr/bin/env fish

set SCRIPT_DIR (dirname (status filename))
set BENCH_SCRIPT "$SCRIPT_DIR/bench/bench.rb"
set INSTANCE_TYPES_FILE "$SCRIPT_DIR/bench/instance_types.json"
set STATUS_FILE "$SCRIPT_DIR/status.json"
set LOG_FILE "$SCRIPT_DIR/bench.log"
set SSH_CONFIG_HELPER "$SCRIPT_DIR/bench/generate_ssh_config.sh"
set FETCH_LOGS_SCRIPT "$SCRIPT_DIR/bench/fetch_logs_via_ssh.sh"
set SSH_CONFIG_FILE "$SCRIPT_DIR/bench/ssh_config"
set -g NONINTERACTIVE false
set -g SSH_CONFIG_GENERATED false

# Return configured instance types as provider:type strings
function list_configured_types
    jq -r 'to_entries[] | "\(.key):\(.value | keys[])"' $INSTANCE_TYPES_FILE 2>/dev/null
end

function get_all_instance_types
    list_configured_types
end

function count_instance_types
    get_all_instance_types | wc -l | string trim
end

# Get completed instance types from a results folder
# Returns types in their canonical form (e.g., "c6g.medium", "Standard_D32pls_v5")
function get_completed_types_from_folder
    set folder_path $argv[1]
    set completed

    for output_file in (find $folder_path -name "output.txt" 2>/dev/null)
        if grep -q "Average of last" $output_file 2>/dev/null
            set result_dir (dirname $output_file)
            set metadata_file "$result_dir/metadata.json"
            set canonical ""
            set provider ""

            if test -f $metadata_file
                set provider (jq -r '.provider // empty' $metadata_file 2>/dev/null)
                set canonical (jq -r '.instance_type // empty' $metadata_file 2>/dev/null)
            end

            if test -z "$canonical"
                set dir_name (basename $result_dir)
                set type_with_dashes (echo $dir_name | sed 's/-[0-9]*$//')
                if string match -q "Standard-*" $type_with_dashes
                    set canonical (echo $type_with_dashes | sed 's/-/_/g')
                else
                    set canonical (echo $type_with_dashes | sed 's/-/./')
                end
            end

            if test -z "$provider"; and test -n "$canonical"
                set provider (jq -r --arg t "$canonical" 'to_entries[] | select(.value[$t]) | .key' $INSTANCE_TYPES_FILE 2>/dev/null | head -1)
            end

            if test -n "$canonical"
                if test -n "$provider"
                    set label "$provider:$canonical"
                else
                    set label $canonical
                end
                if not contains $label $completed
                    set completed $completed $label
                end
            end
        end
    end
    printf '%s\n' $completed
end

# Get pending instance types (configured but not completed)
function get_pending_types
    set folder_path $argv[1]
    set all_types (get_all_instance_types)
    set completed_types (get_completed_types_from_folder $folder_path)

    for t in $all_types
        set provider (string split ":" $t)[1]
        set type_name (string split ":" $t)[2]

        # Exact match
        if contains $t $completed_types
            continue
        end
        # Legacy runs may store just the type name without provider
        if test -n "$type_name"; and contains $type_name $completed_types
            continue
        end
        echo $t
    end
end

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
            echo "Provisioning cloud instances"
        case terraform_init terraform_applying
            echo "Provisioning cloud instances"
        case waiting_for_results
            echo "Waiting for results upload"
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
    if test "$instances_json" != "{}"; and test "$instances_json" != "null"
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
            if test "$inst_status" = "running"; and test -n "$progress_val"; and test "$progress_val" != "null"
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
    if test -n "$updated_at"; and test "$updated_at" != "null"
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

    # Show last 10 lines of log
    if test -f $LOG_FILE
        echo
        gum style --foreground 245 "Recent log:"
        tail -10 $LOG_FILE 2>/dev/null | while read -l line
            gum style --foreground 241 "  $line"
        end
    end

    # Check for completion
    switch $phase
        case complete
            echo
            set results_path (jq -r '.results_path // ""' $STATUS_FILE)
            set successful_count (jq -r '.successful | length' $STATUS_FILE)
            gum style --foreground 82 "All $successful_count instances completed successfully!"
            if test -n "$results_path"; and test "$results_path" != "null"
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
            if test "$NONINTERACTIVE" != "true"
                maybe_generate_ssh_config
                offer_fetch_logs "Fetch logs via bastion now?"
            end
            break
        else if test $status_code -eq 2
            # Failed (status file says failed)
            if test "$NONINTERACTIVE" != "true"
                maybe_generate_ssh_config
                offer_fetch_logs "Fetch logs via bastion for debugging?"
            end
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
                    maybe_generate_ssh_config
                    if test "$NONINTERACTIVE" != "true"
                        offer_fetch_logs "Fetch logs via bastion for debugging?"
                    end
                    break
            end
        end

        sleep 2
    end
end

# Generate SSH config once the infrastructure exists and Terraform outputs are ready
function maybe_generate_ssh_config
    if test "$SSH_CONFIG_GENERATED" = "true"
        return
    end
    if not test -x $SSH_CONFIG_HELPER
        return
    end
    if not test -f $STATUS_FILE
        return
    end
    set phase (jq -r '.phase // ""' $STATUS_FILE 2>/dev/null)
    switch $phase
        case instances_ready waiting_for_results running_benchmarks collecting_results destroying failed complete
            gum log --level info "Generating SSH config for bastion access..."
            spin --spinner dot --title "Generating SSH config..." -- bash $SSH_CONFIG_HELPER >/dev/null
            if test $status -eq 0
                set -g SSH_CONFIG_GENERATED true
                gum log --level info "SSH config ready: $SSH_CONFIG_FILE"
            else
                gum log --level warn "Failed to generate SSH config (Terraform outputs may be unavailable yet)"
            end
        case '*'
            # too early
    end
end

# Offer to fetch logs via bastion
function offer_fetch_logs
    set prompt $argv[1]
    if not test -x $FETCH_LOGS_SCRIPT
        return
    end
    if confirm $prompt
        spin --spinner dot --title "Fetching logs via bastion..." -- bash $FETCH_LOGS_SCRIPT >/dev/null
        if test $status -eq 0
            gum log --level info "Logs downloaded (see results/ssh_logs by default)"
        else
            gum log --level warn "Log fetch failed; check SSH config and bastion connectivity."
        end
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

    gum style --foreground 245 "Select results folder:" >&2
    set choice (printf '%s\n' $choices | gum choose)

    if test -z "$choice"
        # User cancelled
        echo ""
        return
    end

    if string match -q "New folder*" "$choice"
        echo $new_folder_name
    else
        set folder_path "$results_dir/$choice"
        set completed_types (get_completed_types_from_folder $folder_path)
        set pending_types (get_pending_types $folder_path)
        set completed_count (count $completed_types)
        set pending_count (count $pending_types)

        echo >&2
        if test $completed_count -gt 0
            gum style --foreground 82 "Completed ($completed_count types, will be skipped):" >&2
            for ctype in $completed_types
                echo "  ✓ $ctype" >&2
            end
        end

        if test $pending_count -gt 0
            # Count by provider
            set providers
            set provider_counts
            for ptype in $pending_types
                set provider (string split ":" $ptype)[1]
                if test -z "$provider"
                    set provider "unknown"
                end
                set idx (contains -i $provider $providers)
                if test $status -eq 0
                    set provider_counts[$idx] (math $provider_counts[$idx] + 1)
                else
                    set providers $providers $provider
                    set provider_counts $provider_counts 1
                end
            end

            echo >&2
            gum style --foreground 214 "Pending ($pending_count types, will be run):" >&2
            for ptype in $pending_types
                echo "  ○ $ptype" >&2
            end

            # Resolve replicas per provider (defaults: aws=3, azure=2; TF_VAR_replicas applies to both)
            set base_replicas ""
            if set -q TF_VAR_replicas
                set base_replicas $TF_VAR_replicas
            end
            if set -q TF_VAR_aws_replicas
                set aws_replicas $TF_VAR_aws_replicas
            else if test -n "$base_replicas"
                set aws_replicas $base_replicas
            else
                set aws_replicas 3
            end
            if set -q TF_VAR_azure_replicas
                set azure_replicas $TF_VAR_azure_replicas
            else if test -n "$base_replicas"
                set azure_replicas $base_replicas
            else
                set azure_replicas 2
            end

            set total_instances 0
            for idx in (seq (count $providers))
                set provider $providers[$idx]
                set pc $provider_counts[$idx]
                switch $provider
                    case aws
                        set rep $aws_replicas
                    case azure
                        set rep $azure_replicas
                    case '*'
                        if test -n "$base_replicas"
                            set rep $base_replicas
                        else
                            set rep 1
                        end
                end
                set total_instances (math "$total_instances + ($pc * $rep)")
            end
            echo >&2
            gum style --foreground 245 "Will create $total_instances instances" >&2
            if test (count $providers) -gt 0
                for idx in (seq (count $providers))
                    set provider $providers[$idx]
                    set pc $provider_counts[$idx]
                    switch $provider
                        case aws
                            set rep $aws_replicas
                        case azure
                            set rep $azure_replicas
                        case '*'
                            set rep (test -n "$base_replicas"; and echo $base_replicas; or echo 1)
                    end
                    gum style --foreground 245 "  $provider: $pc types × $rep replicas" >&2
                end
            end
        else
            echo >&2
            gum style --foreground 245 "All instance types completed. Nothing to run." >&2
            echo ""
            return
        end

        echo >&2
        if not confirm "Start benchmark?"
            return 1
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

    if not test -f $INSTANCE_TYPES_FILE
        gum log --level error "Instance types config not found: $INSTANCE_TYPES_FILE"
        exit 1
    end

    # Select results folder (this shows completed/pending and confirms)
    set results_folder (select_results_folder)
    or begin
        gum log --level info "Cancelled"
        exit 0
    end
    if test -z "$results_folder"
        gum log --level info "Cancelled"
        exit 0
    end

    echo
    gum log --level info "Starting benchmark in background..."
    gum log --level info "Results folder: results/$results_folder"

    # Start benchmark in background with results folder argument
    ruby $BENCH_SCRIPT --results-folder "$results_folder" > $LOG_FILE 2>&1 &
    set bench_pid $last_pid

    gum log --level info "Benchmark started (PID: $bench_pid)"
    gum log --level info "Log file: $LOG_FILE"
    echo

    sleep 2
    monitor_benchmark
end

function nuke_resources
    gum style --bold --foreground 196 "☢️  NUKE CLOUD RESOURCES"
    echo
    gum style --foreground 245 "This will find and delete ALL ruby-bench-* resources in AWS and Azure,"
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

    # ==================== AWS Resources ====================
    gum style --bold --foreground 214 "AWS Resources"

    # Find instances
    spin --spinner dot --title "Finding EC2 instances..." -- sleep 1
    set instances (aws ec2 describe-instances \
        --region $region \
        --filters "Name=tag:Name,Values=ruby-bench-*" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null | string split -n \t)

    if test (count $instances) -gt 0
        gum log --level warn "Found "(count $instances)" EC2 instances: $instances"
    else
        set instances
        gum log --level info "No EC2 instances found"
    end

    # Find VPC
    set vpc_id (aws ec2 describe-vpcs \
        --region $region \
        --filters "Name=tag:Name,Values=ruby-bench-vpc" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null)

    if test "$vpc_id" != "None"; and test -n "$vpc_id"
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

    # ==================== Azure Resources ====================
    echo
    gum style --bold --foreground 39 "Azure Resources"

    # Check if Azure CLI is available and logged in
    set azure_rgs
    if command -q az
        spin --spinner dot --title "Checking Azure resource groups..." -- sleep 1
        set azure_rgs (az group list --query "[?name=='ruby-bench-rg'].name" -o tsv 2>/dev/null | string split -n \n)
        if test (count $azure_rgs) -gt 0
            gum log --level warn "Found ruby-bench resource groups: $azure_rgs"
        else
            gum log --level info "No ruby-bench resource groups found"
        end
    else
        gum log --level info "Azure CLI not installed, skipping Azure"
    end

    # ==================== Confirmation ====================
    echo

    # Check if anything to delete
    if test (count $instances) -eq 0; and test -z "$vpc_id"; and test "$key_exists" = "no"; and test (count $azure_rgs) -eq 0
        gum log --level info "No ruby-bench resources found. Nothing to delete."
        return 0
    end

    if not confirm --default=false "Delete all these resources?"
        gum log --level info "Cancelled"
        return 0
    end

    echo

    # ==================== Delete AWS Resources ====================
    # Terminate instances
    if test (count $instances) -gt 0
        gum log --level info "Terminating EC2 instances..."
        aws ec2 terminate-instances --region $region --instance-ids $instances > /dev/null 2>&1

        spin --spinner dot --title "Waiting for instances to terminate..." -- \
            aws ec2 wait instance-terminated --region $region --instance-ids $instances 2>/dev/null
        gum log --level info "EC2 instances terminated"
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
        gum log --level info "Deleting AWS key pair..."
        aws ec2 delete-key-pair --region $region --key-name ruby-bench 2>/dev/null
    end

    # ==================== Delete Azure Resources ====================
    if test (count $azure_rgs) -gt 0
        for rg in $azure_rgs
            gum log --level info "Deleting Azure resource group $rg (this deletes all contained resources)..."
            az group delete --name $rg --yes --no-wait >/dev/null 2>&1
            # Wait until the group is gone to avoid leftovers
            set wait_secs 0
            while az group exists --name $rg >/dev/null 2>&1
                set wait_secs (math $wait_secs + 5)
                sleep 5
                if test $wait_secs -ge 600
                    gum log --level warn "Still waiting for $rg deletion after $wait_secs seconds..."
                end
            end
            gum log --level info "Azure resource group $rg deleted"
        end
    end

    # Final cleanup of local files
    rm -f "$terraform_dir/terraform.tfstate" "$terraform_dir/terraform.tfstate.backup" "$terraform_dir/bench-key.pem" 2>/dev/null

    echo
    gum log --level info "Done! All ruby-bench resources have been deleted."

    # ==================== List ALL remaining resources in account ====================
    echo
    gum style --bold --foreground 245 "Remaining resources in account (all resources, not just ruby-bench):"
    echo

    # AWS EC2 instances
    gum style --foreground 214 "AWS EC2 Instances ($region):"
    set all_instances (aws ec2 describe-instances \
        --region $region \
        --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
        --output text 2>/dev/null)
    if test -n "$all_instances"
        echo $all_instances | while read -l line
            set parts (string split \t $line)
            set inst_id $parts[1]
            set inst_type $parts[2]
            set inst_state $parts[3]
            set inst_name $parts[4]
            if test -z "$inst_name"; or test "$inst_name" = "None"
                set inst_name "(no name)"
            end
            echo "  $inst_id  $inst_type  $inst_state  $inst_name"
        end
    else
        echo "  (none)"
    end

    # AWS VPCs (excluding default)
    echo
    gum style --foreground 214 "AWS VPCs ($region):"
    set all_vpcs (aws ec2 describe-vpcs \
        --region $region \
        --query 'Vpcs[?IsDefault==`false`].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
        --output text 2>/dev/null)
    if test -n "$all_vpcs"
        echo $all_vpcs | while read -l line
            set parts (string split \t $line)
            set vpc_id $parts[1]
            set cidr $parts[2]
            set vpc_name $parts[3]
            if test -z "$vpc_name"; or test "$vpc_name" = "None"
                set vpc_name "(no name)"
            end
            echo "  $vpc_id  $cidr  $vpc_name"
        end
    else
        echo "  (none, excluding default VPC)"
    end

    # AWS Key Pairs
    echo
    gum style --foreground 214 "AWS Key Pairs ($region):"
    set all_keys (aws ec2 describe-key-pairs \
        --region $region \
        --query 'KeyPairs[].KeyName' \
        --output text 2>/dev/null)
    if test -n "$all_keys"
        for key in (string split \t $all_keys)
            echo "  $key"
        end
    else
        echo "  (none)"
    end

    # AWS NAT Gateways
    echo
    gum style --foreground 214 "AWS NAT Gateways ($region):"
    set all_nats (aws ec2 describe-nat-gateways \
        --region $region \
        --filter "Name=state,Values=pending,available" \
        --query 'NatGateways[].[NatGatewayId,State,Tags[?Key==`Name`].Value|[0]]' \
        --output text 2>/dev/null)
    if test -n "$all_nats"
        echo $all_nats | while read -l line
            set parts (string split \t $line)
            set nat_id $parts[1]
            set nat_state $parts[2]
            set nat_name $parts[3]
            if test -z "$nat_name"; or test "$nat_name" = "None"
                set nat_name "(no name)"
            end
            echo "  $nat_id  $nat_state  $nat_name"
        end
    else
        echo "  (none)"
    end

    # AWS Elastic IPs
    echo
    gum style --foreground 214 "AWS Elastic IPs ($region):"
    set all_eips (aws ec2 describe-addresses \
        --region $region \
        --query 'Addresses[].[AllocationId,PublicIp,Tags[?Key==`Name`].Value|[0]]' \
        --output text 2>/dev/null)
    if test -n "$all_eips"
        echo $all_eips | while read -l line
            set parts (string split \t $line)
            set eip_id $parts[1]
            set eip_ip $parts[2]
            set eip_name $parts[3]
            if test -z "$eip_name"; or test "$eip_name" = "None"
                set eip_name "(no name)"
            end
            echo "  $eip_id  $eip_ip  $eip_name"
        end
    else
        echo "  (none)"
    end

    # Azure resource groups
    if command -q az
        echo
        gum style --foreground 39 "Azure Resource Groups:"
        set all_rgs (az group list --query '[].name' -o tsv 2>/dev/null)
        if test -n "$all_rgs"
            for rg in $all_rgs
                echo "  $rg"
            end
        else
            echo "  (none)"
        end
    end
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
        set instance_count (cd $terraform_dir && terraform state list 2>/dev/null | grep -E "aws_instance|azurerm_linux_virtual_machine" | wc -l | string trim || echo "0")
        if test "$instance_count" -gt 0
            echo
            gum log --level warn "Found $instance_count cloud instance(s) still running"
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
            gum log --level info "No instances running"
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
    echo "  nuke     Delete ALL ruby-bench cloud resources (AWS + Azure failsafe cleanup)"
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
        nuke_resources
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
        set choice (gum choose "Start new benchmark" "Monitor running benchmark" "Stop benchmark" "Nuke cloud resources" "Show status" "Help")
        switch $choice
            case "Start new benchmark"
                start_benchmark
            case "Monitor running benchmark"
                monitor_benchmark
            case "Stop benchmark"
                stop_benchmark
            case "Nuke cloud resources"
                nuke_resources
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
