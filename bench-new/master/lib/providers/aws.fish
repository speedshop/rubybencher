# AWS provider implementation
# Requires common.fish to be sourced first

function get_aws_vcpu_count
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

    provider_validate_not_local_orchestrator "AWS"

    log_info "Preparing AWS task runner infrastructure..."

    set -g AWS_TF_DIR "$BENCH_DIR/infrastructure/aws"
    set -g AWS_TF_LOG_FILE (log_path_for "aws-terraform")
    set -l meta_tf_dir "$BENCH_DIR/infrastructure/meta"

    if not test -d "$AWS_TF_DIR"
        log_error "AWS infrastructure directory not found: $AWS_TF_DIR"
        exit 1
    end

    # Get configuration values
    set -l ruby_version (cat "$CONFIG_FILE" | jq -r '.ruby_version')
    set -l key_name (terraform -chdir="$meta_tf_dir" output -raw key_name 2>/dev/null || echo "")
    set -l aws_region (terraform -chdir="$meta_tf_dir" output -raw aws_region 2>/dev/null || echo "us-east-1")
    set -l allowed_ssh_cidr (terraform -chdir="$meta_tf_dir" output -raw allowed_ssh_cidr 2>/dev/null || echo "0.0.0.0/0")

    # If key_name not in meta output, try to get from tfvars
    if test -z "$key_name"
        set key_name (grep 'key_name' "$meta_tf_dir/terraform.tfvars" 2>/dev/null | sed 's/.*=[[:space:]]*"\(.*\)"/\1/' | head -1)
    end

    if test -z "$key_name"
        log_error "Could not determine SSH key name from meta terraform"
        exit 1
    end

    # Build instance types JSON and maps using common utilities
    set -l instance_types_json (provider_get_instance_types_json "aws")
    set -l vcpu_map (provider_build_vcpu_map "aws" "get_aws_vcpu_count")
    set -l instance_count_map (provider_build_instance_count_map "aws")

    # Get flags
    set -l mock_flag (provider_get_mock_flag)
    set -l debug_flag (provider_get_debug_flag)

    # Initialize terraform if needed
    if not provider_tf_init_if_needed "$AWS_TF_DIR" "$AWS_TF_LOG_FILE"
        log_error "AWS terraform init failed"
        exit 1
    end

    # Get task runner image from ECR
    set -l task_runner_image "$TASK_RUNNER_IMAGE"
    if test -z "$task_runner_image"
        log_error "TASK_RUNNER_IMAGE not set - ECR build may have failed"
        exit 1
    end

    # Create tfvars file for this run
    echo "aws_region        = \"$aws_region\"
key_name          = \"$key_name\"
run_id            = \"$RUN_ID\"
ruby_version      = \"$ruby_version\"
task_runner_image = \"$task_runner_image\"
instance_types    = $instance_types_json
vcpu_count        = $vcpu_map
instance_count    = $instance_count_map
mock_benchmark    = $mock_flag
debug_mode        = $debug_flag
allowed_ssh_cidr  = \"$allowed_ssh_cidr\"" > "$AWS_TF_DIR/terraform.tfvars"

    if test "$DEBUG" = true
        echo "AWS terraform.tfvars:"
        cat "$AWS_TF_DIR/terraform.tfvars"
    end

    return 0
end

function get_aws_terraform_dir
    echo $AWS_TF_DIR
end

function finalize_aws_task_runners
    # Show output after terraform completes
    set -l meta_tf_dir "$BENCH_DIR/infrastructure/meta"

    provider_show_created_instances "AWS" "$AWS_TF_DIR"

    # Show bastion IP for SSH debugging
    set -l bastion_ip (terraform -chdir="$meta_tf_dir" output -raw bastion_public_ip 2>/dev/null)
    if test -n "$bastion_ip"
        log_info "Bastion IP: $bastion_ip"
        log_info "SSH to task runner: ./infrastructure/meta/ssh-task-runner.fish $bastion_ip <task_runner_ip>"
    end

    log_success "AWS task runners starting (via user-data scripts)..."
    log_info "Task runners will automatically connect to orchestrator and claim tasks"
end

function aws_task_runners_exist
    set -l tf_dir "$BENCH_DIR/infrastructure/aws"
    provider_task_runners_exist "$tf_dir"
end

function aws_run_id_matches
    set -l run_id $argv[1]
    set -l tf_dir "$BENCH_DIR/infrastructure/aws"
    provider_run_id_matches "$tf_dir" "$run_id"
end

function show_existing_aws_task_runners
    set -l tf_dir "$BENCH_DIR/infrastructure/aws"
    provider_show_instances "AWS" "$tf_dir"
end

function update_aws_status
    set -l tf_dir "$BENCH_DIR/infrastructure/aws"
    provider_update_status "aws" "$tf_dir"
end

function setup_aws_task_runners
    # Legacy function for backwards compatibility (runs synchronously)
    if not prepare_aws_task_runners
        return 0
    end

    log_info "Creating AWS task runner instances..."
    if not provider_terraform_apply "$AWS_TF_DIR"
        log_error "Failed to create AWS task runner instances"
        exit 1
    end

    finalize_aws_task_runners
end
