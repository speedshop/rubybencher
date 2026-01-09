function start_local_orchestrator
    if not test "$LOCAL_ORCHESTRATOR" = true
        return 0
    end

    log_info "Starting local orchestrator via docker compose..."

    set -l orchestrator_dir "$BENCH_DIR/orchestrator"

    if not test -f "$orchestrator_dir/docker-compose.yml"
        log_error "docker-compose.yml not found in $orchestrator_dir"
        exit 1
    end

    # Check if already running with same API key
    set -l running_containers (docker compose -f "$orchestrator_dir/docker-compose.yml" ps -q web 2>/dev/null)
    if test -n "$running_containers"
        # Stop existing containers to ensure API key is updated
        log_info "Stopping existing orchestrator to apply new API key..."
        docker compose -f "$orchestrator_dir/docker-compose.yml" down 2>/dev/null
    end

    # Start the stack with the API key
    log_info "Using API key: $API_KEY"
    gum spin --spinner dot --title "Starting docker compose stack..." -- \
        env API_KEY="$API_KEY" docker compose -f "$orchestrator_dir/docker-compose.yml" up -d --build

    if test $status -ne 0
        log_error "Failed to start docker compose stack"
        exit 1
    end

    # Set the orchestrator URL for local mode
    set -g ORCHESTRATOR_URL "http://localhost:3000"

    log_success "Local orchestrator starting..."
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
            set -l status_url (status_get '.meta.orchestrator_url')
            if test -n "$status_url"
                set -g ORCHESTRATOR_URL "$status_url"
            end
        end

        if test -z "$API_KEY"
            set -l status_key (status_get '.meta.api_key')
            if test -n "$status_key"
                set -g API_KEY "$status_key"
            end
        end

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

    if test "$RESUME_META" = true
        if test -z "$ORCHESTRATOR_URL"; and test -n "$STATUS_ORCHESTRATOR_URL"
            set -g ORCHESTRATOR_URL "$STATUS_ORCHESTRATOR_URL"
        end
        if test -z "$API_KEY"; and test -n "$STATUS_API_KEY"
            set -g API_KEY "$STATUS_API_KEY"
        end
        if test -z "$S3_BUCKET"; and test -n "$STATUS_S3_BUCKET_NAME"
            set -g S3_BUCKET "$STATUS_S3_BUCKET_NAME"
        end
    end

    if test -z "$ORCHESTRATOR_URL"
        set -g ORCHESTRATOR_URL (terraform -chdir="$tf_dir" output -raw orchestrator_url 2>/dev/null)
    end

    if test -z "$API_KEY"
        set -g API_KEY (terraform -chdir="$tf_dir" output -raw api_key 2>/dev/null)
    end

    if test -z "$S3_BUCKET"
        set -g S3_BUCKET (terraform -chdir="$tf_dir" output -raw s3_bucket_name 2>/dev/null)
    end

    if test -z "$ORCHESTRATOR_URL"
        log_error "Failed to get orchestrator URL from terraform"
        exit 1
    end

    if test -z "$API_KEY"
        log_error "Failed to get API key from terraform"
        exit 1
    end

    set -l bastion_public_ip (terraform -chdir="$tf_dir" output -raw bastion_public_ip 2>/dev/null)
    if test -z "$bastion_public_ip"
        set bastion_public_ip (status_get '.meta.bastion_public_ip')
    end

    set -l orchestrator_public_ip (terraform -chdir="$tf_dir" output -raw orchestrator_public_ip 2>/dev/null)
    if test -z "$orchestrator_public_ip"
        set orchestrator_public_ip (status_get '.meta.orchestrator_public_ip')
    end

    set -l aws_region (terraform -chdir="$tf_dir" output -raw aws_region 2>/dev/null)
    if test -z "$aws_region"
        set aws_region (status_get '.meta.aws_region')
    end

    set -l key_name (terraform -chdir="$tf_dir" output -raw key_name 2>/dev/null)
    if test -z "$key_name"
        set key_name (status_get '.meta.key_name')
    end

    set -l s3_bucket_name (terraform -chdir="$tf_dir" output -raw s3_bucket_name 2>/dev/null)
    if test -z "$s3_bucket_name"
        set s3_bucket_name (status_get '.meta.s3_bucket_name')
    end

    status_set_meta "$ORCHESTRATOR_URL" "$API_KEY" "$bastion_public_ip" "$orchestrator_public_ip" "$aws_region" "$key_name" "$s3_bucket_name"
end

function orchestrator_reachable
    set -l url $argv[1]

    if test -z "$url"
        return 1
    end

    set -l response (curl -s -o /dev/null -w "%{http_code}" "$url/up" 2>/dev/null)
    test "$response" = "200"
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
            open "$ORCHESTRATOR_URL"
            return 0
        end

        gum spin --spinner dot --title "Waiting for orchestrator (attempt $attempt/$max_attempts)..." -- sleep 5
        set attempt (math $attempt + 1)
    end

    log_error "Orchestrator did not become ready in time"
    exit 1
end
