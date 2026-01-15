function print_usage
    echo "Usage: run.fish [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE         Config file path (required)"
    echo "  -k, --api-key KEY         API key (generated randomly if not provided)"
    echo "  -p, --provider PROVIDER   Only run for specific provider (aws, azure, local)"
    echo "  --local-orchestrator      Run orchestrator locally via docker compose"
    echo "  --skip-infra              Skip terraform, use existing infrastructure"
    echo "  --reuse-orchestrator      Reuse orchestrator from orchestrator.json"
    echo "  --resume-run ID|latest    Resume an existing run ID"
    echo "  --mock                    Run mock benchmark instead of real benchmark"
    echo "  --debug                   Enable debug mode (verbose output, keeps task runners alive)"
    echo "  --non-interactive         Skip all interactive prompts (for CI/automation)"
    echo "  -h, --help                Show this help"
    echo ""
    echo "Environment Variables:"
    echo "  BENCHMARK_ORCHESTRATOR_URL  Override orchestrator URL"
    echo ""
    echo "Examples:"
    echo "  # Run with local orchestrator (auto-generates API key)"
    echo "  run.fish -c config/example.json --local-orchestrator"
    echo ""
    echo "  # Run with specific API key"
    echo "  run.fish -c config/example.json --local-orchestrator -k my-secret-key"
    echo ""
    echo "  # Run with AWS infrastructure"
    echo "  run.fish -c config/aws-full.json"
end

function parse_args
    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case -c --config
                set i (math $i + 1)
                set -g CONFIG_FILE $argv[$i]
            case -k --api-key
                set i (math $i + 1)
                set -g API_KEY $argv[$i]
                set -g CLI_API_KEY true
            case -p --provider
                set i (math $i + 1)
                set -g PROVIDER_FILTER $argv[$i]
            case --local-orchestrator
                set -g LOCAL_ORCHESTRATOR true
                set -g CLI_LOCAL_ORCHESTRATOR true
            case --skip-infra
                set -g SKIP_INFRA true
                set -g CLI_SKIP_INFRA true
            case --reuse-orchestrator
                set -g REUSE_ORCHESTRATOR true
            case --resume-run
                set i (math $i + 1)
                set -g RESUME_RUN_TARGET $argv[$i]
            case --mock
                set -g MOCK_BENCHMARK true
                set -g CLI_MOCK_BENCHMARK true
            case --debug
                set -g DEBUG true
                set -g CLI_DEBUG true
            case --non-interactive
                set -g NON_INTERACTIVE true
                set -g CLI_NON_INTERACTIVE true
            case -h --help
                print_usage
                exit 0
            case '*'
                log_error "Unknown option: $argv[$i]"
                print_usage
                exit 1
        end
        set i (math $i + 1)
    end
end

function validate_config
    if test -z "$CONFIG_FILE"
        log_error "Config file is required (-c/--config)"
        print_usage
        exit 1
    end

    # Handle relative paths - resolve from current working directory
    if not string match -q '/*' "$CONFIG_FILE"
        set -g CONFIG_FILE (realpath "$CONFIG_FILE" 2>/dev/null; or echo "$CONFIG_FILE")
    end

    if not test -f "$CONFIG_FILE"
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    end

    # Validate JSON syntax
    if not cat "$CONFIG_FILE" | jq . >/dev/null 2>&1
        log_error "Invalid JSON in config file: $CONFIG_FILE"
        exit 1
    end

    # Validate required fields
    set -l ruby_version (cat "$CONFIG_FILE" | jq -r '.ruby_version // empty')
    if test -z "$ruby_version"
        log_error "Config file missing required field: ruby_version"
        exit 1
    end

    set -l runs_per (cat "$CONFIG_FILE" | jq -r '.runs_per_instance_type // empty')
    if test -z "$runs_per"
        log_error "Config file missing required field: runs_per_instance_type"
        exit 1
    end
end

function load_config_options
    # Load options from config file, but CLI options take precedence

    if test "$CLI_LOCAL_ORCHESTRATOR" = false
        set -l config_val (cat "$CONFIG_FILE" | jq -r '.local_orchestrator // false')
        if test "$config_val" = "true"
            set -g LOCAL_ORCHESTRATOR true
        end
    end

    if test "$CLI_SKIP_INFRA" = false
        set -l config_val (cat "$CONFIG_FILE" | jq -r '.skip_infra // false')
        if test "$config_val" = "true"
            set -g SKIP_INFRA true
        end
    end

    if test "$CLI_MOCK_BENCHMARK" = false
        set -l config_val (cat "$CONFIG_FILE" | jq -r '.mock // false')
        if test "$config_val" = "true"
            set -g MOCK_BENCHMARK true
        end
    end

    if test "$CLI_DEBUG" = false
        set -l config_val (cat "$CONFIG_FILE" | jq -r '.debug // false')
        if test "$config_val" = "true"
            set -g DEBUG true
        end
    end

    if test "$CLI_NON_INTERACTIVE" = false
        set -l config_val (cat "$CONFIG_FILE" | jq -r '.non_interactive // false')
        if test "$config_val" = "true"
            set -g NON_INTERACTIVE true
        end
    end

    if test "$CLI_API_KEY" = false
        set -l config_val (cat "$CONFIG_FILE" | jq -r '.api_key // empty')
        if test -n "$config_val"; and test "$config_val" != "null"
            set -g API_KEY "$config_val"
        end
    end
end

function get_task_runner_count
    # Get the number of task runners to start for a given provider
    # Supports:
    #   task_runners.count: 3              (applies to all providers)
    #   task_runners.count.local: 3        (provider-specific)
    # Defaults to 1 if not specified
    set -l provider $argv[1]

    # First check for provider-specific count (only if count is an object)
    set -l provider_count (cat "$CONFIG_FILE" | jq -r --arg p "$provider" 'if .task_runners.count | type == "object" then .task_runners.count[$p] // empty else empty end')
    if test -n "$provider_count"; and test "$provider_count" != "null"
        echo $provider_count
        return
    end

    # Then check for global count (if count is a number, not an object)
    set -l global_count (cat "$CONFIG_FILE" | jq -r 'if .task_runners.count | type == "number" then .task_runners.count else empty end')
    if test -n "$global_count"; and test "$global_count" != "null"
        echo $global_count
        return
    end

    # Default to 1
    echo 1
end

function get_task_runner_cap
    # Get the optional max task runner count for a provider.
    # Returns empty if not specified in config.
    set -l provider $argv[1]

    # First check for provider-specific count (only if count is an object)
    set -l provider_count (cat "$CONFIG_FILE" | jq -r --arg p "$provider" 'if .task_runners.count | type == "object" then .task_runners.count[$p] // empty else empty end')
    if test -n "$provider_count"; and test "$provider_count" != "null"
        echo $provider_count
        return
    end

    # Then check for global count (if count is a number, not an object)
    set -l global_count (cat "$CONFIG_FILE" | jq -r 'if .task_runners.count | type == "number" then .task_runners.count else empty end')
    if test -n "$global_count"; and test "$global_count" != "null"
        echo $global_count
        return
    end
end

function filter_config_for_provider
    set -l config_content (cat "$CONFIG_FILE")

    if test -n "$PROVIDER_FILTER"
        # Create filtered config with only the specified provider
        set -l filtered (echo $config_content | jq --arg provider "$PROVIDER_FILTER" '{
            ruby_version: .ruby_version,
            runs_per_instance_type: .runs_per_instance_type,
            task_runners: .task_runners,
            ($provider): .[$provider]
        } | with_entries(select(.value != null))')

        echo $filtered
    else
        echo $config_content
    end
end
