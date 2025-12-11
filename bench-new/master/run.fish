#!/usr/bin/env fish
# Master Script - Ruby Cross Cloud Benchmark Runner
# Orchestrates infrastructure standup, benchmark execution, and result collection

set -g SCRIPT_DIR (dirname (status --current-filename))
set -g BENCH_DIR (dirname $SCRIPT_DIR)
set -g REPO_ROOT (dirname $BENCH_DIR)
set -g RESULTS_DIR "$REPO_ROOT/results"

# Default values
set -g CONFIG_FILE ""
set -g PROVIDER_FILTER ""
set -g LOCAL_ORCHESTRATOR false
set -g SKIP_INFRA false
set -g DEBUG false
set -g API_KEY ""
set -g MOCK_BENCHMARK false

function print_usage
    echo "Usage: run.fish [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE         Config file path (required)"
    echo "  -k, --api-key KEY         API key (generated randomly if not provided)"
    echo "  -p, --provider PROVIDER   Only run for specific provider (aws, azure, local)"
    echo "  --local-orchestrator      Run orchestrator locally via docker-compose"
    echo "  --skip-infra              Skip terraform, use existing infrastructure"
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

function log_info
    gum style --foreground 212 "→ $argv"
end

function log_success
    gum style --foreground 82 "✓ $argv"
end

function log_error
    gum style --foreground 196 "✗ $argv"
end

function log_warning
    gum style --foreground 214 "⚠ $argv"
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
            case -p --provider
                set i (math $i + 1)
                set -g PROVIDER_FILTER $argv[$i]
            case --local-orchestrator
                set -g LOCAL_ORCHESTRATOR true
            case --skip-infra
                set -g SKIP_INFRA true
            case --mock
                set -g MOCK_BENCHMARK true
            case --debug
                set -g DEBUG true
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

function generate_api_key
    # Generate a random 32-character hex string
    if command -q openssl
        openssl rand -hex 16
    else
        cat /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | head -c 32
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

function check_dependencies
    log_info "Checking dependencies..."

    set -l missing_deps

    for dep in jq curl gum
        if not command -q $dep
            set missing_deps $missing_deps $dep
        end
    end

    if test "$LOCAL_ORCHESTRATOR" = true
        if not command -q docker
            set missing_deps $missing_deps docker
        end
    else if not test "$SKIP_INFRA" = true
        if not command -q terraform
            set missing_deps $missing_deps terraform
        end
    end

    if test (count $missing_deps) -gt 0
        log_error "Missing dependencies: $missing_deps"
        exit 1
    end

    log_success "All dependencies found"
end

function start_local_orchestrator
    if not test "$LOCAL_ORCHESTRATOR" = true
        return 0
    end

    log_info "Starting local orchestrator via docker-compose..."

    set -l orchestrator_dir "$BENCH_DIR/orchestrator"

    if not test -f "$orchestrator_dir/docker-compose.yml"
        log_error "docker-compose.yml not found in $orchestrator_dir"
        exit 1
    end

    # Check if already running with same API key
    set -l running_containers (docker-compose -f "$orchestrator_dir/docker-compose.yml" ps -q web 2>/dev/null)
    if test -n "$running_containers"
        # Stop existing containers to ensure API key is updated
        log_info "Stopping existing orchestrator to apply new API key..."
        docker-compose -f "$orchestrator_dir/docker-compose.yml" down 2>/dev/null
    end

    # Start the stack with the API key
    log_info "Using API key: $API_KEY"
    gum spin --spinner dot --title "Starting docker-compose stack..." -- \
        env API_KEY="$API_KEY" docker-compose -f "$orchestrator_dir/docker-compose.yml" up -d --build

    if test $status -ne 0
        log_error "Failed to start docker-compose stack"
        exit 1
    end

    # Set the orchestrator URL for local mode
    set -g ORCHESTRATOR_URL "http://localhost:3000"

    log_success "Local orchestrator starting..."
end

function stop_local_orchestrator
    if not test "$LOCAL_ORCHESTRATOR" = true
        return 0
    end

    log_info "Stopping local orchestrator..."

    set -l orchestrator_dir "$BENCH_DIR/orchestrator"

    docker-compose -f "$orchestrator_dir/docker-compose.yml" down

    log_success "Local orchestrator stopped"
end

function setup_infrastructure
    if test "$SKIP_INFRA" = true
        log_warning "Skipping infrastructure setup (--skip-infra)"
        return 0
    end

    if test "$LOCAL_ORCHESTRATOR" = true
        # Local orchestrator is handled separately
        return 0
    end

    log_info "Setting up AWS infrastructure..."

    set -l tf_dir "$BENCH_DIR/infrastructure/meta"

    if not test -d "$tf_dir"
        log_error "Terraform directory not found: $tf_dir"
        exit 1
    end

    # Check for tfvars
    if not test -f "$tf_dir/terraform.tfvars"
        log_error "terraform.tfvars not found in $tf_dir"
        log_error "Copy terraform.tfvars.example and fill in your values"
        exit 1
    end

    # Initialize terraform if needed
    if not test -d "$tf_dir/.terraform"
        gum spin --spinner dot --title "Initializing Terraform..." -- \
            terraform -chdir="$tf_dir" init
    end

    # Plan and apply
    gum spin --spinner dot --title "Planning infrastructure changes..." -- \
        terraform -chdir="$tf_dir" plan -out=tfplan

    echo ""
    if not gum confirm "Apply infrastructure changes?"
        log_warning "Infrastructure setup cancelled"
        exit 0
    end

    gum spin --spinner dot --title "Applying infrastructure..." -- \
        terraform -chdir="$tf_dir" apply -auto-approve tfplan

    if test $status -ne 0
        log_error "Terraform apply failed"
        exit 1
    end

    rm -f "$tf_dir/tfplan"
    log_success "Infrastructure ready"
end

function initialize_api_key
    # API key can come from: command line (-k), or auto-generated
    # For local orchestrator and skip-infra modes, we control the key
    # For terraform mode, the key comes from terraform output

    if test "$LOCAL_ORCHESTRATOR" = true; or test "$SKIP_INFRA" = true
        if test -z "$API_KEY"
            log_info "Generating random API key..."
            set -g API_KEY (generate_api_key)
        end
        log_info "API key: $API_KEY"
    end
    # For terraform mode, API key will be fetched from terraform output later
end

function get_orchestrator_config
    # Environment variable can override orchestrator URL
    if set -q BENCHMARK_ORCHESTRATOR_URL
        set -g ORCHESTRATOR_URL "$BENCHMARK_ORCHESTRATOR_URL"
    end

    if test "$LOCAL_ORCHESTRATOR" = true
        # URL was set by start_local_orchestrator
        if test -z "$ORCHESTRATOR_URL"
            set -g ORCHESTRATOR_URL "http://localhost:3000"
        end
        # API key was already set by initialize_api_key
        return 0
    end

    if test "$SKIP_INFRA" = true
        # Using existing infrastructure - need orchestrator URL
        if test -z "$ORCHESTRATOR_URL"
            log_error "BENCHMARK_ORCHESTRATOR_URL environment variable is required with --skip-infra"
            exit 1
        end
        log_success "Using orchestrator at: $ORCHESTRATOR_URL"
        return 0
    end

    # Terraform mode - get config from terraform outputs
    set -l tf_dir "$BENCH_DIR/infrastructure/meta"

    log_info "Getting orchestrator configuration from terraform..."

    set -g ORCHESTRATOR_URL (terraform -chdir="$tf_dir" output -raw orchestrator_url 2>/dev/null)
    set -g API_KEY (terraform -chdir="$tf_dir" output -raw api_key 2>/dev/null)
    set -g S3_BUCKET (terraform -chdir="$tf_dir" output -raw s3_bucket_name 2>/dev/null)

    if test -z "$ORCHESTRATOR_URL"
        log_error "Failed to get orchestrator URL from terraform"
        exit 1
    end

    if test -z "$API_KEY"
        log_error "Failed to get API key from terraform"
        exit 1
    end

    log_success "Orchestrator URL: $ORCHESTRATOR_URL"
end

function wait_for_orchestrator
    log_info "Waiting for orchestrator to be ready..."

    set -l max_attempts 60
    set -l attempt 1

    while test $attempt -le $max_attempts
        set -l health_url "$ORCHESTRATOR_URL/up"
        set -l response (curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null)

        if test "$response" = "200"
            log_success "Orchestrator is ready"
            log_info "Orchestrator URL: $ORCHESTRATOR_URL"
            return 0
        end

        gum spin --spinner dot --title "Waiting for orchestrator (attempt $attempt/$max_attempts)..." -- sleep 5
        set attempt (math $attempt + 1)
    end

    log_error "Orchestrator did not become ready in time"
    exit 1
end

function start_local_task_runners
    # Check if local provider is in the config
    set -l local_instances (cat "$CONFIG_FILE" | jq -r '.local // empty')
    if test -z "$local_instances"; or test "$local_instances" = "null"
        return 0
    end

    log_info "Starting local task runners..."

    set -l task_runner_dir "$BENCH_DIR/task-runner"
    set -l ruby_version (cat "$CONFIG_FILE" | jq -r '.ruby_version')

    # Build the task runner image
    log_info "Building task runner image..."
    docker build -t task-runner:$ruby_version \
        --build-arg RUBY_VERSION=$ruby_version \
        "$task_runner_dir" >/dev/null 2>&1
    or begin
        log_error "Failed to build task runner image"
        exit 1
    end

    # For local provider, the orchestrator URL needs to be accessible from the container
    set -l container_orchestrator_url "$ORCHESTRATOR_URL"
    if test "$LOCAL_ORCHESTRATOR" = true
        # If orchestrator is running in docker-compose, use host.docker.internal
        set container_orchestrator_url "http://host.docker.internal:3000"
    end

    # Start a task runner for each instance type in the local config
    for i in (seq 0 (math (cat "$CONFIG_FILE" | jq '.local | length') - 1))
        set -l instance_type (cat "$CONFIG_FILE" | jq -r ".local[$i].instance_type")
        set -l instance_alias (cat "$CONFIG_FILE" | jq -r ".local[$i].alias")
        set -l container_name "task-runner-local-$instance_alias-$RUN_ID"

        log_info "Starting task runner for local/$instance_alias ($instance_type)..."

        set -l mock_flag ""
        if test "$MOCK_BENCHMARK" = true
            set mock_flag "--mock"
        end

        set -l debug_flags ""
        if test "$DEBUG" = true
            set debug_flags "--debug --no-exit"
        end

        docker run -d \
            --name "$container_name" \
            --add-host=host.docker.internal:host-gateway \
            task-runner:$ruby_version \
            --orchestrator-url "$container_orchestrator_url" \
            --api-key "$API_KEY" \
            --run-id "$RUN_ID" \
            --provider "local" \
            --instance-type "$instance_type" \
            $mock_flag $debug_flags >/dev/null
        or begin
            log_error "Failed to start task runner for $instance_alias"
            exit 1
        end

        log_success "Started task runner: $container_name"
    end
end

function stop_local_task_runners
    # Stop any task runner containers for this run
    if test -z "$RUN_ID"
        return 0
    end

    set -l containers (docker ps -aq --filter "name=task-runner-local-.*-$RUN_ID" 2>/dev/null)
    if test -n "$containers"
        log_info "Stopping local task runners..."
        docker rm -f $containers >/dev/null 2>&1
        log_success "Stopped local task runners"
    end
end

function filter_config_for_provider
    set -l config_content (cat "$CONFIG_FILE")

    if test -n "$PROVIDER_FILTER"
        # Create filtered config with only the specified provider
        set -l filtered (echo $config_content | jq --arg provider "$PROVIDER_FILTER" '{
            ruby_version: .ruby_version,
            runs_per_instance_type: .runs_per_instance_type,
            ($provider): .[$provider]
        } | with_entries(select(.value != null))')

        echo $filtered
    else
        echo $config_content
    end
end

function create_run
    log_info "Creating benchmark run..."

    set -l config_json (filter_config_for_provider)

    if test "$DEBUG" = true
        echo "Config being sent:"
        echo $config_json | jq .
    end

    set -l response (curl -s -X POST "$ORCHESTRATOR_URL/runs" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$config_json")

    if test "$DEBUG" = true
        echo "Response:"
        echo $response | jq .
    end

    # Parse response
    set -g RUN_ID (echo $response | jq -r '.run_id // empty')
    set -l tasks_created (echo $response | jq -r '.tasks_created // 0')
    set -l error_msg (echo $response | jq -r '.error // empty')

    if test -z "$RUN_ID"
        log_error "Failed to create run: $error_msg"
        exit 1
    end

    log_success "Created run $RUN_ID with $tasks_created tasks"
end

function display_progress
    set -l run_id $argv[1]

    set -l response (curl -s "$ORCHESTRATOR_URL/runs/$run_id" \
        -H "Authorization: Bearer $API_KEY")

    set -l run_status (echo $response | jq -r '.status')
    set -l total (echo $response | jq -r '.tasks.total')
    set -l pending (echo $response | jq -r '.tasks.pending')
    set -l claimed (echo $response | jq -r '.tasks.claimed')
    set -l running (echo $response | jq -r '.tasks.running')
    set -l completed (echo $response | jq -r '.tasks.completed')
    set -l failed (echo $response | jq -r '.tasks.failed')

    # Calculate progress percentage
    set -l done_count (math $completed + $failed)
    set -l progress 0
    if test $total -gt 0
        set progress (math "round($done_count * 100 / $total)")
    end

    # Build status line
    set -l status_line "[$progress%] "
    set status_line "$status_line""Pending: $pending | "
    set status_line "$status_line""Running: "(math $claimed + $running)" | "
    set status_line "$status_line""✓ $completed | "
    set status_line "$status_line""✗ $failed"

    echo $status_line

    echo $run_status
end

function poll_run_status
    log_info "Waiting for benchmark to complete..."

    set -l poll_interval 10

    while true
        set -l response (curl -s "$ORCHESTRATOR_URL/runs/$RUN_ID" \
            -H "Authorization: Bearer $API_KEY")
        set -l run_status (echo $response | jq -r '.status')

        if test "$run_status" = "completed"; or test "$run_status" = "cancelled"
            log_success "Run $run_status"
            break
        end

        sleep $poll_interval
    end
end

function download_results
    log_info "Downloading results..."

    set -l response (curl -s "$ORCHESTRATOR_URL/runs/$RUN_ID" \
        -H "Authorization: Bearer $API_KEY")

    set -l gzip_url (echo $response | jq -r '.gzip_url // empty')

    if test -z "$gzip_url"; or test "$gzip_url" = "null"
        log_warning "No results gzip available yet"
        if test "$DEBUG" = true
            echo "API response:"
            echo $response | jq .
        end
        return 1
    end

    # Create results directory
    set -l run_results_dir "$RESULTS_DIR/$RUN_ID"
    mkdir -p "$run_results_dir"

    log_info "Downloading results archive..."
    if test "$DEBUG" = true
        log_info "Download URL: $gzip_url"
    end

    set -l http_code (curl -s -w "%{http_code}" -o "$run_results_dir/results.tar.gz" "$gzip_url")

    if test "$http_code" != "200"
        log_error "Failed to download results (HTTP $http_code)"
        log_error "URL: $gzip_url"
        if test -f "$run_results_dir/results.tar.gz"
            set -l error_content (cat "$run_results_dir/results.tar.gz" 2>/dev/null | head -c 500)
            if test -n "$error_content"
                log_error "Response body: $error_content"
            end
            rm -f "$run_results_dir/results.tar.gz"
        end
        return 1
    end

    if not test -f "$run_results_dir/results.tar.gz"
        log_error "Failed to download results: file not created"
        return 1
    end

    # Verify it's a valid gzip file
    if not gzip -t "$run_results_dir/results.tar.gz" 2>/dev/null
        log_error "Downloaded file is not a valid gzip archive"
        if test "$DEBUG" = true
            log_error "File contents:"
            head -c 200 "$run_results_dir/results.tar.gz"
        end
        return 1
    end

    log_info "Extracting results..."

    tar -xzf "$run_results_dir/results.tar.gz" -C "$run_results_dir"
    if test $status -ne 0
        log_error "Failed to extract results archive"
        return 1
    end

    rm "$run_results_dir/results.tar.gz"
    log_success "Results saved to: $run_results_dir"
end

function cleanup_on_interrupt
    echo ""
    log_warning "Interrupted! Cleaning up..."

    # Always stop local task runners if they were started
    stop_local_task_runners

    if gum confirm "Run nuke script to clean up infrastructure?"
        fish "$BENCH_DIR/nuke/nuke.fish"
    end

    exit 130
end

function main
    # Parse command line arguments
    parse_args $argv

    # Display banner
    gum style \
        --border double \
        --align center \
        --width 50 \
        --margin "1" \
        --padding "1" \
        "Ruby Cross Cloud Benchmark" \
        "Master Script"

    # Validate inputs
    validate_config
    check_dependencies

    # Show config summary
    echo ""
    log_info "Configuration:"
    echo "  Config file: $CONFIG_FILE"
    echo "  Ruby version: "(cat "$CONFIG_FILE" | jq -r '.ruby_version')
    echo "  Runs per instance: "(cat "$CONFIG_FILE" | jq -r '.runs_per_instance_type')
    if test -n "$PROVIDER_FILTER"
        echo "  Provider filter: $PROVIDER_FILTER"
    end
    if test "$LOCAL_ORCHESTRATOR" = true
        echo "  Mode: Local orchestrator (docker-compose)"
    end
    echo ""

    # Set up signal handler
    trap cleanup_on_interrupt SIGINT SIGTERM

    # Initialize API key (generate if needed for local/skip-infra modes)
    initialize_api_key

    # Start local orchestrator if requested (uses API_KEY)
    start_local_orchestrator

    # Setup infrastructure (unless local-orchestrator or skip-infra)
    setup_infrastructure

    # Get orchestrator configuration
    get_orchestrator_config

    # Wait for orchestrator to be ready
    wait_for_orchestrator

    # Create the benchmark run
    create_run

    # Start task runners for local provider (if configured)
    start_local_task_runners

    # Monitor progress
    poll_run_status

    # Stop local task runners
    stop_local_task_runners

    # Download results
    download_results

    # Final summary
    echo ""
    gum style \
        --border rounded \
        --align center \
        --width 50 \
        --padding "1" \
        --foreground 82 \
        "Benchmark Complete!" \
        "Run ID: $RUN_ID" \
        "Results: $RESULTS_DIR/$RUN_ID"

    # Offer to clean up infrastructure
    echo ""
    if gum confirm "Run nuke script to clean up infrastructure?"
        fish "$BENCH_DIR/nuke/nuke.fish"
    end
end

# Run main
main $argv
