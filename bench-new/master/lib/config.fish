function print_usage
    echo "Usage: run.fish [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE         Config file path (required)"
    echo "  -k, --api-key KEY         API key (generated randomly if not provided)"

    echo "  --local-orchestrator      Run orchestrator locally via docker compose"
    echo "  --skip-infra              Skip terraform, use existing infrastructure"
    echo "  --reuse-orchestrator      Reuse orchestrator from orchestrator.json"
    echo "  --resume-run ID|latest    Resume an existing run ID"
    echo "  --mock                    Run mock benchmark instead of real benchmark"
    echo "  --debug                   Enable debug mode (verbose output, keeps task runners alive)"
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

    if test "$CLI_API_KEY" = false
        set -l config_val (cat "$CONFIG_FILE" | jq -r '.api_key // empty')
        if test -n "$config_val"; and test "$config_val" != "null"
            set -g API_KEY "$config_val"
        end
    end
end

function get_task_runner_count
    # Get the number of task runners to start for a given provider
    # Supports (in priority order):
    #   aws.task_runners.count: 3          (provider object)
    #   task_runners.count: 3              (global default)
    # Defaults to 1 if not specified
    set -l provider $argv[1]

    # First check for provider object style: aws.task_runners.count
    set -l provider_obj_count (cat "$CONFIG_FILE" | jq -r --arg p "$provider" '.[$p].task_runners.count // empty')
    if test -n "$provider_obj_count"; and test "$provider_obj_count" != "null"
        echo $provider_obj_count
        return
    end

    # Then check for global number: task_runners.count
    set -l global_count (cat "$CONFIG_FILE" | jq -r '.task_runners.count // empty')
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
    # Uses same priority as get_task_runner_count
    set -l provider $argv[1]

    # First check for provider object style: aws.task_runners.count
    set -l provider_obj_count (cat "$CONFIG_FILE" | jq -r --arg p "$provider" '.[$p].task_runners.count // empty')
    if test -n "$provider_obj_count"; and test "$provider_obj_count" != "null"
        echo $provider_obj_count
        return
    end

    # Then check for global: task_runners.count
    set -l global_count (cat "$CONFIG_FILE" | jq -r '.task_runners.count // empty')
    if test -n "$global_count"; and test "$global_count" != "null"
        echo $global_count
        return
    end
end

function get_runs_per_instance_type
    # Get the number of benchmark runs per instance type for a given provider
    # Supports (in priority order):
    #   aws.runs_per_instance_type: 3      (provider object, new style)
    #   runs_per_instance_type: 3          (global default)
    # Required field - will error if not found
    set -l provider $argv[1]

    # First check for provider object style: aws.runs_per_instance_type
    set -l provider_runs (cat "$CONFIG_FILE" | jq -r --arg p "$provider" '.[$p].runs_per_instance_type // empty')
    if test -n "$provider_runs"; and test "$provider_runs" != "null"
        echo $provider_runs
        return
    end

    # Then check for global runs_per_instance_type
    set -l global_runs (cat "$CONFIG_FILE" | jq -r '.runs_per_instance_type // empty')
    if test -n "$global_runs"; and test "$global_runs" != "null"
        echo $global_runs
        return
    end

    # No default - this is a required field
    log_error "Config file missing runs_per_instance_type (global or for provider: $provider)"
    exit 1
end

function get_provider_instances_jq_path
    # Returns the jq path to the instances array for a provider
    # Supports both formats:
    #   Old: .aws (array at top level)
    #   New: .aws.instances (object with instances key)
    set -l provider $argv[1]

    # Check if provider config is an object with instances key
    set -l has_instances_key (cat "$CONFIG_FILE" | jq -r --arg p "$provider" 'if .[$p] | type == "object" and (.[$p].instances | type == "array") then "true" else "false" end')

    if test "$has_instances_key" = "true"
        echo ".[\"$provider\"].instances"
    else
        echo ".[\"$provider\"]"
    end
end


