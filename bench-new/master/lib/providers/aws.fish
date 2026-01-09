function get_vcpu_count
    # Get the vCPU count for an AWS instance type
    # Returns 1 for .medium instances, 2 for .large, etc.
    set -l instance_type $argv[1]

    # Extract the size suffix (medium, large, xlarge, etc.)
    set -l size (string match -r '\.(nano|micro|small|medium|large|xlarge|[0-9]+xlarge)$' $instance_type | tail -1 | string replace '.' '')

    switch $size
        case nano micro small medium
            echo 1
        case large
            echo 2
        case xlarge
            echo 4
        case 2xlarge
            echo 8
        case 4xlarge
            echo 16
        case 8xlarge
            echo 32
        case 12xlarge
            echo 48
        case 16xlarge
            echo 64
        case 24xlarge
            echo 96
        case '*'
            # Default to 1 if unknown
            echo 1
    end
end

function prepare_aws_task_runners
    # Prepare AWS task runners: validation, config building, terraform init
    # Returns 0 if ready to proceed, 1 if nothing to do
    set -l aws_instances (cat "$CONFIG_FILE" | jq -r '.aws // empty')
    if test -z "$aws_instances"; or test "$aws_instances" = "null"
        return 1
    end

    if test "$LOCAL_ORCHESTRATOR" = true
        log_error "AWS task runners cannot be used with --local-orchestrator"
        log_error "AWS instances need to reach the orchestrator over the internet"
        exit 1
    end

    log_info "Preparing AWS task runner infrastructure..."

    set -g AWS_TF_DIR "$BENCH_DIR/infrastructure/aws"
    set -l meta_tf_dir "$BENCH_DIR/infrastructure/meta"

    if not test -d "$AWS_TF_DIR"
        log_error "AWS infrastructure directory not found: $AWS_TF_DIR"
        exit 1
    end

    # Get configuration values
    set -l ruby_version (cat "$CONFIG_FILE" | jq -r '.ruby_version')
    set -l key_name (terraform -chdir="$meta_tf_dir" output -raw key_name 2>/dev/null || echo "")
    set -l aws_region (terraform -chdir="$meta_tf_dir" output -raw aws_region 2>/dev/null || echo "us-east-1")

    # If key_name not in meta output, try to get from tfvars
    if test -z "$key_name"
        set key_name (grep 'key_name' "$meta_tf_dir/terraform.tfvars" 2>/dev/null | sed 's/.*=\s*"\(.*\)"/\1/' | head -1)
    end

    if test -z "$key_name"
        log_error "Could not determine SSH key name from meta terraform"
        exit 1
    end

    # Build instance types JSON
    set -l instance_types_json (cat "$CONFIG_FILE" | jq -c '.aws')

    # Get the number of runs per instance type - this determines how many task runner slots we need
    set -l min_runners (cat "$CONFIG_FILE" | jq -r '.runs_per_instance_type')

    # Optional cap for task runners per instance
    set -l runner_cap (get_task_runner_cap "aws")

    # Build vcpu_count map and instance_count map
    set -l vcpu_map "{"
    set -l instance_count_map "{"
    set -l first true
    for i in (seq 0 (math (cat "$CONFIG_FILE" | jq '.aws | length') - 1))
        set -l alias_name (cat "$CONFIG_FILE" | jq -r ".aws[$i].alias")
        set -l instance_type (cat "$CONFIG_FILE" | jq -r ".aws[$i].instance_type")
        set -l vcpu (get_vcpu_count $instance_type)
        set -l effective_vcpu $vcpu

        if test -n "$runner_cap"; and test "$runner_cap" != "null"
            if test $runner_cap -lt $effective_vcpu
                set effective_vcpu $runner_cap
            end
        end

        if test $effective_vcpu -lt 1
            set effective_vcpu 1
        end

        set -l instances_needed (math "ceil($min_runners / $effective_vcpu)")

        if test "$first" = true
            set first false
        else
            set vcpu_map "$vcpu_map,"
            set instance_count_map "$instance_count_map,"
        end
        set vcpu_map "$vcpu_map\"$alias_name\":$effective_vcpu"
        set instance_count_map "$instance_count_map\"$alias_name\":$instances_needed"
    end
    set vcpu_map "$vcpu_map}"
    set instance_count_map "$instance_count_map}"

    # Prepare mock and debug flags
    set -l mock_flag "false"
    if test "$MOCK_BENCHMARK" = true
        set mock_flag "true"
    end

    set -l debug_flag "false"
    if test "$DEBUG" = true
        set debug_flag "true"
    end

    # Initialize terraform if needed
    if not test -d "$AWS_TF_DIR/.terraform"
        gum spin --spinner dot --title "Initializing AWS task runner Terraform..." -- \
            terraform -chdir="$AWS_TF_DIR" init
    end

    # Create tfvars file for this run
    echo "aws_region      = \"$aws_region\"
key_name        = \"$key_name\"
run_id          = \"$RUN_ID\"
ruby_version    = \"$ruby_version\"
instance_types  = $instance_types_json
vcpu_count      = $vcpu_map
instance_count  = $instance_count_map
mock_benchmark  = $mock_flag
debug_mode      = $debug_flag" > "$AWS_TF_DIR/terraform.tfvars"

    if test "$DEBUG" = true
        echo "AWS terraform.tfvars:"
        cat "$AWS_TF_DIR/terraform.tfvars"
    end

    return 0
end

function get_aws_terraform_dir
    # Return the AWS terraform directory (must call prepare_aws_task_runners first)
    echo $AWS_TF_DIR
end

function finalize_aws_task_runners
    # Show output after terraform completes
    set -l meta_tf_dir "$BENCH_DIR/infrastructure/meta"

    # Show created instances
    set -l instances (terraform -chdir="$AWS_TF_DIR" output -json task_runner_instances 2>/dev/null)
    if test -n "$instances"
        log_success "AWS task runner instances created:"
        echo $instances | jq -r 'to_entries[] | "  \(.key): \(.value.instance_type) (\(.value.public_ip))"'
    end

    # Show bastion IP for SSH debugging
    set -l bastion_ip (terraform -chdir="$meta_tf_dir" output -raw bastion_public_ip 2>/dev/null)
    if test -n "$bastion_ip"
        log_info "Bastion IP: $bastion_ip"
        log_info "SSH to task runner: ./infrastructure/meta/ssh-task-runner.fish $bastion_ip <task_runner_ip>"
    end

    log_success "AWS task runners starting (via user-data scripts)..."
    log_info "Task runners will automatically connect to orchestrator and claim tasks"
end

function setup_aws_task_runners
    # Legacy function for backwards compatibility (runs synchronously)
    if not prepare_aws_task_runners
        return 0
    end

    log_info "Creating AWS task runner instances..."
    terraform -chdir="$AWS_TF_DIR" apply -auto-approve -parallelism=30

    if test $status -ne 0
        log_error "Failed to create AWS task runner instances"
        exit 1
    end

    finalize_aws_task_runners
end
