# Fargate provider implementation
# Requires common.fish to be sourced first

function prepare_fargate_task_runners
    # Prepare Fargate task runners: validation, config building, terraform init
    # Returns 0 if ready to proceed, 1 if nothing to do
    set -l instance_types_json (provider_get_instance_types_json "fargate")
    if test -z "$instance_types_json"; or test "$instance_types_json" = "null"; or test "$instance_types_json" = "[]"
        return 1
    end

    provider_validate_not_local_orchestrator "Fargate"

    log_info "Preparing Fargate task runner infrastructure..."

    set -g FARGATE_TF_DIR "$BENCH_DIR/infrastructure/fargate"
    set -g FARGATE_TF_LOG_FILE (log_path_for "fargate-terraform")
    set -l meta_tf_dir "$BENCH_DIR/infrastructure/meta"

    if not test -d "$FARGATE_TF_DIR"
        log_error "Fargate infrastructure directory not found: $FARGATE_TF_DIR"
        exit 1
    end

    # Get configuration values
    set -l ruby_version (cat "$CONFIG_FILE" | jq -r '.ruby_version')
    set -l aws_region (terraform -chdir="$meta_tf_dir" output -raw aws_region 2>/dev/null || echo "us-east-1")

    # Build instance count map using common utilities
    set -l instance_count_map (provider_build_instance_count_map "fargate")

    # Get flags
    set -l mock_flag (provider_get_mock_flag)
    set -l debug_flag (provider_get_debug_flag)

    # Initialize terraform if needed
    if not provider_tf_init_if_needed "$FARGATE_TF_DIR" "$FARGATE_TF_LOG_FILE"
        log_error "Fargate terraform init failed"
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
run_id            = \"$RUN_ID\"
ruby_version      = \"$ruby_version\"
task_runner_image = \"$task_runner_image\"
instance_types    = $instance_types_json
instance_count    = $instance_count_map
mock_benchmark    = $mock_flag
debug_mode        = $debug_flag" > "$FARGATE_TF_DIR/terraform.tfvars"

    if test "$DEBUG" = true
        echo "Fargate terraform.tfvars:"
        cat "$FARGATE_TF_DIR/terraform.tfvars"
    end

    return 0
end

function get_fargate_terraform_dir
    echo $FARGATE_TF_DIR
end

function finalize_fargate_task_runners
    provider_show_created_instances "Fargate" "$FARGATE_TF_DIR"
    log_success "Fargate task runners starting (via ECS services)..."
    log_info "Task runners will automatically connect to orchestrator and claim tasks"
end

function fargate_task_runners_exist
    set -l tf_dir "$BENCH_DIR/infrastructure/fargate"
    provider_task_runners_exist "$tf_dir"
end

function fargate_run_id_matches
    set -l run_id $argv[1]
    set -l tf_dir "$BENCH_DIR/infrastructure/fargate"
    provider_run_id_matches "$tf_dir" "$run_id"
end

function show_existing_fargate_task_runners
    set -l tf_dir "$BENCH_DIR/infrastructure/fargate"
    provider_show_instances "Fargate" "$tf_dir"
end

function update_fargate_status
    set -l tf_dir "$BENCH_DIR/infrastructure/fargate"
    provider_update_status "fargate" "$tf_dir"
end

function setup_fargate_task_runners
    # Legacy function for backwards compatibility (runs synchronously)
    if not prepare_fargate_task_runners
        return 0
    end

    log_info "Creating Fargate task runner services..."
    if not provider_terraform_apply "$FARGATE_TF_DIR"
        log_error "Failed to create Fargate task runner services"
        exit 1
    end

    finalize_fargate_task_runners
end
