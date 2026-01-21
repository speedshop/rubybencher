# Provider registry and dispatcher
# Central hub for provider management

function provider_list
    echo aws
    echo azure
    echo local
end

function provider_in_config
    set -l provider $argv[1]
    set -l count (cat "$CONFIG_FILE" | jq -r --arg p "$provider" 'if .[$p] then (.[$p] | length) else 0 end')

    if test "$count" -gt 0
        return 0
    end

    return 1
end

function configured_providers
    set -l providers

    for provider in (provider_list)
        if provider_in_config $provider
            set providers $providers $provider
        end
    end

    if test (count $providers) -gt 0
        printf "%s\n" $providers
    end
end

function provider_phase
    set -l provider $argv[1]

    switch $provider
        case local
            echo post_run
        case aws azure
            echo pre_orchestrator
        case '*'
            echo pre_orchestrator
    end
end

function provider_validate
    # Validation is now handled by individual providers during setup
    # This function remains for backwards compatibility
    set -l provider $argv[1]

    switch $provider
        case aws azure local
            return 0
        case '*'
            log_error "Unknown provider: $provider"
            exit 1
    end
end

function provider_setup_task_runners
    set -l provider $argv[1]

    switch $provider
        case aws
            setup_aws_task_runners
        case azure
            setup_azure_task_runners
        case local
            start_local_task_runners
        case '*'
            log_error "Unknown provider: $provider"
            exit 1
    end
end

# Provider terraform directory lookup
function provider_get_terraform_dir
    set -l provider $argv[1]

    switch $provider
        case aws
            echo "$BENCH_DIR/infrastructure/aws"
        case azure
            echo "$BENCH_DIR/infrastructure/azure"
        case '*'
            echo ""
    end
end

# Check if provider has existing task runners
function provider_has_existing_runners
    set -l provider $argv[1]

    switch $provider
        case aws
            aws_task_runners_exist
        case azure
            azure_task_runners_exist
        case '*'
            return 1
    end
end

# Check if provider's run_id matches
function provider_matches_run_id
    set -l provider $argv[1]
    set -l run_id $argv[2]

    switch $provider
        case aws
            aws_run_id_matches "$run_id"
        case azure
            azure_run_id_matches "$run_id"
        case '*'
            return 1
    end
end

# Show existing task runners for a provider
function provider_show_existing_runners
    set -l provider $argv[1]

    switch $provider
        case aws
            show_existing_aws_task_runners
        case azure
            show_existing_azure_task_runners
    end
end

# Update status file for a provider
function provider_status_update
    set -l provider $argv[1]

    switch $provider
        case aws
            update_aws_status
        case azure
            update_azure_status
    end
end
