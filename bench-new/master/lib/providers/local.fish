function start_local_task_runners
    # Check if local provider is in the config
    set -l local_instances (cat "$CONFIG_FILE" | jq -r '.local // empty')
    if test -z "$local_instances"; or test "$local_instances" = "null"
        return 0
    end

    log_info "Starting local task runners..."

    set -l task_runner_dir "$BENCH_DIR/task-runner"
    set -l ruby_version (cat "$CONFIG_FILE" | jq -r '.ruby_version')

    set -l running_names (docker ps --format '{{.Names}}' 2>/dev/null)
    set -l existing_names (docker ps -a --format '{{.Names}}' 2>/dev/null)

    # For local provider, the orchestrator URL needs to be accessible from the container
    set -l container_orchestrator_url "$ORCHESTRATOR_URL"
    if test "$LOCAL_ORCHESTRATOR" = true
        # If orchestrator is running in docker-compose, use host.docker.internal
        set container_orchestrator_url "http://host.docker.internal:3000"
    end

    # Get the number of task runners to start for local provider
    set -l runner_count (get_per_instance_type_instances "local")
    log_info "Starting $runner_count task runner(s) per instance type..."

    # Start task runners for each instance type in the local config
    for i in (seq 0 (math (cat "$CONFIG_FILE" | jq '.local | length') - 1))
        set -l instance_type (cat "$CONFIG_FILE" | jq -r ".local[$i].instance_type")
        set -l instance_alias (cat "$CONFIG_FILE" | jq -r ".local[$i].alias")

        # Start the configured number of task runners for this instance type
        for runner_idx in (seq 1 $runner_count)
            set -l container_name "task-runner-local-$instance_alias-$runner_idx-$RUN_ID"

            if contains -- $container_name $running_names
                log_info "Task runner already running: $container_name"
                continue
            end

            if contains -- $container_name $existing_names
                log_info "Starting existing task runner container: $container_name"
                docker start "$container_name" >/dev/null
                or begin
                    log_error "Failed to start existing task runner $container_name"
                    exit 1
                end

                log_success "Started task runner: $container_name"
                continue
            end

            # Build the task runner image (only if we need to launch new containers)
            if not set -q TASK_RUNNER_IMAGE_READY
                set -g TASK_RUNNER_IMAGE_READY true
                log_info "Building task runner image..."
                docker build -t task-runner:$ruby_version \
                    --build-arg RUBY_VERSION=$ruby_version \
                    "$task_runner_dir" >/dev/null 2>&1
                or begin
                    log_error "Failed to build task runner image"
                    exit 1
                end
            end

            log_info "Starting task runner $runner_idx/$runner_count for local/$instance_alias ($instance_type)..."

            set -l mock_flag ""
            if test "$MOCK_BENCHMARK" = true
                set mock_flag "--mock"
            end

            set -l debug_flags
            if test "$DEBUG" = true
                set debug_flags --debug --no-exit
            end

            docker run -d \
                --name "$container_name" \
                --add-host=host.docker.internal:host-gateway \
                --cpus=1 \
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
end
