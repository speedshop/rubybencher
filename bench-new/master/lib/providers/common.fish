# Common provider utilities
# Shared functions for cloud provider implementations

# ============================================================================
# Terraform State Operations
# ============================================================================

function provider_tf_state_exists
    # Check if terraform state exists for a provider
    # Usage: provider_tf_state_exists $tf_dir
    set -l tf_dir $argv[1]
    test -f "$tf_dir/terraform.tfstate"
end

function provider_tf_init_if_needed
    # Initialize terraform if .terraform directory doesn't exist
    # Usage: provider_tf_init_if_needed $tf_dir $log_file
    set -l tf_dir $argv[1]
    set -l log_file $argv[2]

    if not test -d "$tf_dir/.terraform"
        run_logged_command "$log_file" terraform -chdir="$tf_dir" init
        return $status
    end
    return 0
end

function provider_tf_ensure_initialized
    # Ensure terraform is initialized (silently, for state queries)
    # Usage: provider_tf_ensure_initialized $tf_dir
    set -l tf_dir $argv[1]

    if not test -d "$tf_dir/.terraform"
        terraform -chdir="$tf_dir" init -input=false >/dev/null 2>&1
    end
end

function provider_run_id_matches
    # Check if the terraform state run_id matches the current run
    # Usage: provider_run_id_matches $tf_dir $run_id
    set -l tf_dir $argv[1]
    set -l run_id $argv[2]

    if not provider_tf_state_exists "$tf_dir"
        return 1
    end

    set -l existing_run_id (terraform -chdir="$tf_dir" output -raw run_id 2>/dev/null)
    test -n "$existing_run_id"; and test "$existing_run_id" = "$run_id"
end

function provider_task_runners_exist
    # Check if task runner instances exist in terraform state
    # Usage: provider_task_runners_exist $tf_dir
    set -l tf_dir $argv[1]

    if not provider_tf_state_exists "$tf_dir"
        return 1
    end

    provider_tf_ensure_initialized "$tf_dir"

    set -l instances (terraform -chdir="$tf_dir" output -json task_runner_instances 2>/dev/null)
    if test -z "$instances"; or test "$instances" = "null"
        return 1
    end

    set -l count (echo $instances | jq -r 'length')
    test "$count" -gt 0
end

function provider_get_output
    # Get a terraform output value
    # Usage: provider_get_output $tf_dir $output_name [--json]
    set -l tf_dir $argv[1]
    set -l output_name $argv[2]
    set -l format_flag "-raw"

    if test "$argv[3]" = "--json"
        set format_flag "-json"
    end

    terraform -chdir="$tf_dir" output $format_flag $output_name 2>/dev/null
end

# ============================================================================
# Instance Display
# ============================================================================

function provider_show_instances
    # Display existing task runner instances
    # Usage: provider_show_instances $provider $tf_dir
    set -l provider $argv[1]
    set -l tf_dir $argv[2]

    set -l instances (provider_get_output "$tf_dir" "task_runner_instances" --json)
    if test -n "$instances"; and test "$instances" != "null"
        log_success "$provider task runner instances already present:"
        echo $instances | jq -r 'to_entries[] | "  \(.key): \(.value.instance_type) (\(.value.public_ip))"'
    end
end

function provider_show_created_instances
    # Display newly created task runner instances
    # Usage: provider_show_created_instances $provider $tf_dir
    set -l provider $argv[1]
    set -l tf_dir $argv[2]

    set -l instances (provider_get_output "$tf_dir" "task_runner_instances" --json)
    if test -n "$instances"
        log_success "$provider task runner instances created:"
        echo $instances | jq -r 'to_entries[] | "  \(.key): \(.value.instance_type) (\(.value.public_ip))"'
    end
end

# ============================================================================
# Status Updates
# ============================================================================

function provider_update_status
    # Update the run status file with provider outputs
    # Usage: provider_update_status $provider $tf_dir [extra_fields...]
    # Extra fields are passed as jq args, e.g., --arg resource_group "mygroup"
    set -l provider $argv[1]
    set -l tf_dir $argv[2]
    set -l extra_args $argv[3..-1]

    set -l now (date -u +"%Y-%m-%dT%H:%M:%SZ")

    set -l instances (provider_get_output "$tf_dir" "task_runner_instances" --json)
    if test -z "$instances"; or test "$instances" = "null"
        log_warning "Unable to update run status file with $provider outputs"
        return 1
    end

    set -l instance_ids (provider_get_output "$tf_dir" "task_runner_instance_ids" --json)
    if test -z "$instance_ids"; or test "$instance_ids" = "null"
        set instance_ids "[]"
    end

    set -l public_ips (echo $instances | jq -c '[.[] | .public_ip]')

    # Build the base jq expression
    set -l jq_expr "(.providers //= {}) |
         .providers.$provider = {
           tf_dir: \$tf_dir,
           last_apply_at: \$last_apply_at,
           instance_ids: \$instance_ids,
           public_ips: \$public_ips
         }"

    # Add extra fields if provided
    for arg in $extra_args
        if string match -q -- '--arg' $arg
            continue
        end
        if string match -qr '^[a-z_]+$' -- $arg
            set jq_expr "$jq_expr | .providers.$provider.$arg = \$$arg"
        end
    end

    run_status_update \
        "$jq_expr" \
        --arg tf_dir "$tf_dir" \
        --arg last_apply_at "$now" \
        --argjson instance_ids "$instance_ids" \
        --argjson public_ips "$public_ips" \
        $extra_args
end

# ============================================================================
# Configuration Helpers
# ============================================================================

function provider_get_mock_flag
    # Return "true" or "false" based on MOCK_BENCHMARK
    if test "$MOCK_BENCHMARK" = true
        echo "true"
    else
        echo "false"
    end
end

function provider_get_debug_flag
    # Return "true" or "false" based on DEBUG
    if test "$DEBUG" = true
        echo "true"
    else
        echo "false"
    end
end

function provider_build_vcpu_map
    # Build a JSON map of alias -> vcpu_count
    # Usage: provider_build_vcpu_map $provider $vcpu_getter_func
    # The vcpu_getter_func should be a function that takes instance_type and returns vcpu count
    set -l provider $argv[1]
    set -l vcpu_getter $argv[2]

    set -l instances_path (get_provider_instances_jq_path "$provider")
    set -l count (cat "$CONFIG_FILE" | jq "$instances_path | length")

    set -l vcpu_map "{"
    set -l first true

    for i in (seq 0 (math $count - 1))
        set -l alias_name (cat "$CONFIG_FILE" | jq -r "$instances_path"'['"$i"'].alias')
        set -l instance_type (cat "$CONFIG_FILE" | jq -r "$instances_path"'['"$i"'].instance_type')
        set -l vcpu ($vcpu_getter $instance_type)

        if test $vcpu -lt 1
            set vcpu 1
        end

        if test "$first" = true
            set first false
        else
            set vcpu_map "$vcpu_map,"
        end
        set vcpu_map "$vcpu_map\"$alias_name\":$vcpu"
    end

    echo "$vcpu_map}"
end

function provider_build_instance_count_map
    # Build a JSON map of alias -> instance_count
    # Usage: provider_build_instance_count_map $provider
    set -l provider $argv[1]

    set -l instances_path (get_provider_instances_jq_path "$provider")
    set -l count (cat "$CONFIG_FILE" | jq "$instances_path | length")
    set -l instances_per_type (get_per_instance_type_instances "$provider")

    set -l instance_count_map "{"
    set -l first true

    for i in (seq 0 (math $count - 1))
        set -l alias_name (cat "$CONFIG_FILE" | jq -r "$instances_path"'['"$i"'].alias')

        if test "$first" = true
            set first false
        else
            set instance_count_map "$instance_count_map,"
        end
        set instance_count_map "$instance_count_map\"$alias_name\":$instances_per_type"
    end

    echo "$instance_count_map}"
end

function provider_get_instance_types_json
    # Get the instance types array as JSON
    # Usage: provider_get_instance_types_json $provider
    set -l provider $argv[1]

    set -l instances_path (get_provider_instances_jq_path "$provider")
    cat "$CONFIG_FILE" | jq -c "$instances_path"
end

# ============================================================================
# Terraform Apply
# ============================================================================

function provider_terraform_apply
    # Run terraform apply with standard options
    # Usage: provider_terraform_apply $tf_dir
    set -l tf_dir $argv[1]

    terraform -chdir="$tf_dir" apply -auto-approve -parallelism=30
end

# ============================================================================
# Cloud Provider Validation
# ============================================================================

function provider_validate_not_local_orchestrator
    # Validate that cloud providers aren't used with --local-orchestrator
    # Usage: provider_validate_not_local_orchestrator $provider
    set -l provider $argv[1]

    if test "$LOCAL_ORCHESTRATOR" = true
        log_error "$provider task runners cannot be used with --local-orchestrator"
        log_error "Cloud instances need to reach the orchestrator over the internet"
        exit 1
    end
end
