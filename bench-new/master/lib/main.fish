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

    # Validate inputs and load config options
    validate_config
    load_config_options
    check_dependencies

    # Show config summary
    echo ""
    log_info "Configuration ($CONFIG_FILE):"
    jq . "$CONFIG_FILE"
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

    # Generate run ID early so we can start AWS terraform in parallel
    set -g RUN_ID (generate_run_id)
    log_info "Generated run ID: $RUN_ID"

    # Check if AWS provider is configured (for parallelization)
    set -l has_aws_instances (cat "$CONFIG_FILE" | jq -r '.aws // empty')
    set -l aws_terraform_pid ""

    # Start AWS terraform in background if AWS is configured and not using local orchestrator
    if test -n "$has_aws_instances"; and test "$has_aws_instances" != "null"; and test "$LOCAL_ORCHESTRATOR" != true; and test "$SKIP_INFRA" != true
        log_info "Starting AWS task runner setup in parallel with orchestrator wait..."
        setup_aws_task_runners &
        set aws_terraform_pid $last_pid
    end

    # Wait for orchestrator to be ready
    wait_for_orchestrator

    # Create the benchmark run (uses pre-generated RUN_ID)
    create_run

    # Start task runners for local provider (if configured)
    start_local_task_runners

    # Wait for AWS terraform to complete if it was started in background
    if test -n "$aws_terraform_pid"
        log_info "Waiting for AWS task runner setup to complete..."
        wait $aws_terraform_pid
        set -l aws_status $status
        if test $aws_status -ne 0
            log_error "AWS task runner setup failed"
            exit 1
        end
        log_success "AWS task runner setup completed"
    else if test -n "$has_aws_instances"; and test "$has_aws_instances" != "null"; and test "$LOCAL_ORCHESTRATOR" = true
        # AWS was skipped due to local orchestrator - show the error message
        setup_aws_task_runners
    end

    # Monitor progress
    poll_run_status

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
    if test "$NON_INTERACTIVE" = false
        if gum confirm "Run nuke script to clean up infrastructure?"
            fish "$BENCH_DIR/nuke/nuke.fish" -f
        end
    end
end
