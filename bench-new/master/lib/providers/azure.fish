# Azure provider implementation
# Requires common.fish to be sourced first

function get_azure_vcpu_count
    # Get the vCPU count for an Azure VM size (e.g. Standard_D2s_v5 -> 2)
    set -l instance_type $argv[1]
    set -l count (string replace -r 'Standard_[A-Za-z]+([0-9]+).*' '$1' $instance_type)

    if string match -qr '^[0-9]+$' -- $count
        echo $count
    else
        echo 1
    end
end

function azure_effective_region
    set -l azure_region "northcentralus"
    if set -q AZURE_REGION
        set azure_region "$AZURE_REGION"
    end
    echo $azure_region
end

function azure_validate_credentials
    # Validate Azure credentials are present
    set -l missing_vars
    for var in ARM_SUBSCRIPTION_ID ARM_TENANT_ID ARM_CLIENT_ID ARM_CLIENT_SECRET
        if not set -q $var; or test -z (eval echo \$$var)
            set missing_vars $missing_vars $var
        end
    end

    if test (count $missing_vars) -gt 0
        log_error "Missing Azure credentials: $missing_vars"
        log_error "Set ARM_* environment variables for Terraform Azure provider"
        exit 1
    end
end

function azure_get_ssh_public_key
    # Extract SSH public key from meta terraform configuration
    set -l meta_tf_dir $argv[1]

    set -l key_name (terraform -chdir="$meta_tf_dir" output -raw key_name 2>/dev/null || echo "")
    if test -z "$key_name"
        set key_name (grep -E '^[[:space:]]*key_name' "$meta_tf_dir/terraform.tfvars" 2>/dev/null | sed -E 's/.*=[[:space:]]*"(.*)"/\1/' | head -1)
    end

    set -l private_key_path ""
    set -l private_key_path_line (grep -E '^[[:space:]]*private_key_path' "$meta_tf_dir/terraform.tfvars" 2>/dev/null | head -1)
    if test -n "$private_key_path_line"
        set private_key_path (string replace -r '^.*=[[:space:]]*"' '' -- $private_key_path_line)
        set private_key_path (string replace -r '"[[:space:]]*$' '' -- $private_key_path)
    end
    if test -z "$private_key_path"
        log_error "Could not determine private_key_path from meta terraform"
        exit 1
    end

    # Expand the path
    set -l expanded_private_key_path ""
    if string match -qr '^~' -- $private_key_path
        set expanded_private_key_path (string replace -r '^~' $HOME -- $private_key_path)
    else if string match -qr '^/' -- $private_key_path
        set expanded_private_key_path $private_key_path
    else
        set expanded_private_key_path "$meta_tf_dir/$private_key_path"
    end

    # Try to get public key
    set -l ssh_public_key ""
    if test -f "$expanded_private_key_path"; and command -q ssh-keygen
        set ssh_public_key (ssh-keygen -y -f "$expanded_private_key_path" 2>/dev/null)
    end

    if test -z "$ssh_public_key"
        if test -f "$expanded_private_key_path.pub"
            set ssh_public_key (cat "$expanded_private_key_path.pub")
        else if test -n "$key_name"; and test -f "$HOME/.ssh/$key_name.pub"
            set ssh_public_key (cat "$HOME/.ssh/$key_name.pub")
        end
    end

    if test -z "$ssh_public_key"
        log_error "Could not determine SSH public key for Azure"
        exit 1
    end

    string trim -- $ssh_public_key
end

function prepare_azure_task_runners
    # Prepare Azure task runners: validation, config building, terraform init
    # Returns 0 if ready to proceed, 1 if nothing to do
    set -l instance_types_json $argv[1]
    if test -z "$instance_types_json"
        set instance_types_json (provider_get_instance_types_json "azure")
    end

    if test -z "$instance_types_json"; or test "$instance_types_json" = "null"; or test "$instance_types_json" = "[]"
        return 1
    end

    provider_validate_not_local_orchestrator "Azure"

    log_info "Preparing Azure task runner infrastructure..."

    azure_validate_credentials

    set -g AZURE_TF_DIR "$BENCH_DIR/infrastructure/azure"
    set -g AZURE_TF_LOG_FILE (log_path_for "azure-terraform")
    set -l meta_tf_dir "$BENCH_DIR/infrastructure/meta"

    if not test -d "$AZURE_TF_DIR"
        log_error "Azure infrastructure directory not found: $AZURE_TF_DIR"
        exit 1
    end

    # Get configuration values
    set -l ruby_version (cat "$CONFIG_FILE" | jq -r '.ruby_version')
    set -l azure_region (azure_effective_region)

    set -l admin_username "azureuser"
    if set -q AZURE_ADMIN_USERNAME
        set admin_username "$AZURE_ADMIN_USERNAME"
    end

    set -l allowed_ssh_cidr "0.0.0.0/0"
    if set -q AZURE_ALLOWED_SSH_CIDR
        set allowed_ssh_cidr "$AZURE_ALLOWED_SSH_CIDR"
    end

    set -l ssh_public_key (azure_get_ssh_public_key "$meta_tf_dir")

    # Build maps using common utilities
    set -l vcpu_map (provider_build_vcpu_map "azure" "get_azure_vcpu_count")
    set -l instance_count_map (provider_build_instance_count_map "azure")

    # Get flags
    set -l mock_flag (provider_get_mock_flag)
    set -l debug_flag (provider_get_debug_flag)

    # Initialize terraform if needed
    if not provider_tf_init_if_needed "$AZURE_TF_DIR" "$AZURE_TF_LOG_FILE"
        log_error "Azure terraform init failed"
        exit 1
    end

    # Create tfvars file for this run
    echo "azure_region   = \"$azure_region\"
run_id         = \"$RUN_ID\"
ruby_version   = \"$ruby_version\"
instance_types = $instance_types_json
vcpu_count     = $vcpu_map
instance_count = $instance_count_map
mock_benchmark = $mock_flag
debug_mode     = $debug_flag
ssh_public_key = \"$ssh_public_key\"
admin_username = \"$admin_username\"
allowed_ssh_cidr = \"$allowed_ssh_cidr\"" > "$AZURE_TF_DIR/terraform.tfvars"

    if test "$DEBUG" = true
        echo "Azure terraform.tfvars:"
        cat "$AZURE_TF_DIR/terraform.tfvars"
    end

    return 0
end

function get_azure_terraform_dir
    echo $AZURE_TF_DIR
end

function finalize_azure_task_runners
    provider_show_created_instances "Azure" "$AZURE_TF_DIR"
    log_success "Azure task runners starting (via cloud-init scripts)..."
    log_info "Task runners will automatically connect to orchestrator and claim tasks"
end

function azure_task_runners_exist
    set -l tf_dir "$BENCH_DIR/infrastructure/azure"
    provider_task_runners_exist "$tf_dir"
end

function azure_run_id_matches
    set -l run_id $argv[1]
    set -l tf_dir "$BENCH_DIR/infrastructure/azure"
    provider_run_id_matches "$tf_dir" "$run_id"
end

function show_existing_azure_task_runners
    set -l tf_dir "$BENCH_DIR/infrastructure/azure"
    provider_show_instances "Azure" "$tf_dir"
end

function update_azure_status
    set -l tf_dir "$BENCH_DIR/infrastructure/azure"
    set -l now (date -u +"%Y-%m-%dT%H:%M:%SZ")

    set -l instances (provider_get_output "$tf_dir" "task_runner_instances" --json)
    if test -z "$instances"; or test "$instances" = "null"
        log_warning "Unable to update run status file with Azure outputs"
        return 1
    end

    set -l instance_ids (provider_get_output "$tf_dir" "task_runner_instance_ids" --json)
    if test -z "$instance_ids"; or test "$instance_ids" = "null"
        set instance_ids "[]"
    end

    set -l public_ips (echo $instances | jq -c '[.[] | .public_ip]')
    set -l resource_group (provider_get_output "$tf_dir" "resource_group_name")

    # Azure has an extra field (resource_group)
    run_status_update \
        '(.providers //= {}) |
         .providers.azure = {
           tf_dir: $tf_dir,
           last_apply_at: $last_apply_at,
           resource_group: $resource_group,
           instance_ids: $instance_ids,
           public_ips: $public_ips
         }' \
        --arg tf_dir "$tf_dir" \
        --arg last_apply_at "$now" \
        --arg resource_group "$resource_group" \
        --argjson instance_ids "$instance_ids" \
        --argjson public_ips "$public_ips"
end

function setup_azure_task_runners
    # Legacy function for backwards compatibility (runs synchronously)
    if not prepare_azure_task_runners
        return 0
    end

    log_info "Creating Azure task runner instances..."
    if not provider_terraform_apply "$AZURE_TF_DIR"
        log_error "Failed to create Azure task runner instances"
        exit 1
    end

    finalize_azure_task_runners
end
