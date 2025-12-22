function cleanup_local_containers
    if not command -q docker
        log_warning "Docker not found - skipping local cleanup"
        return 0
    end

    log_info "Cleaning up local Docker resources..."

    # Stop orchestrator containers
    set -l orchestrator_dir "$BENCH_DIR/orchestrator"

    if test -f "$orchestrator_dir/docker-compose.yml"
        log_info "Stopping orchestrator containers..."

        cd "$orchestrator_dir"
        docker compose down -v 2>/dev/null || true
        cd -

        log_success "Orchestrator containers stopped"
    end

    # Stop any task runner containers
    log_info "Stopping task runner containers..."

    set -l task_containers (docker ps -aq --filter "name=task-runner-local-" 2>/dev/null)

    if test -n "$task_containers"
        docker rm -f $task_containers 2>/dev/null || true
        log_success "Task runner containers stopped"
    else
        log_success "No task runner containers found"
    end

    # Clean up dangling images (always)
    log_info "Removing dangling Docker images..."
    docker image prune -f 2>/dev/null || true
    log_success "Dangling images removed"
end
