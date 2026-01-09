function provider_list
    echo aws azure local
end

function provider_in_config
    set -l provider $argv[1]
    set -l count (cat "$CONFIG_FILE" | jq -r --arg p "$provider" 'if .[$p] then (.[$p] | length) else 0 end')

    if test "$count" -gt 0
        return 0
    end

    return 1
end

function provider_selected
    set -l provider $argv[1]

    if test -n "$PROVIDER_FILTER"
        test "$PROVIDER_FILTER" = "$provider"
        return $status
    end

    return 0
end

function configured_providers
    set -l providers

    for provider in (provider_list)
        if provider_in_config $provider; and provider_selected $provider
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
    set -l provider $argv[1]

    switch $provider
        case aws azure
            if test "$LOCAL_ORCHESTRATOR" = true
                log_error "$provider task runners cannot be used with --local-orchestrator"
                log_error "Cloud instances need to reach the orchestrator over the internet"
                exit 1
            end
        case local
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
