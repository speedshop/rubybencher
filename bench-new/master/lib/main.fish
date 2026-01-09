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

    # Initialize tmux pane tracking
    tmux_init_pane_tracking

    # Initialize API key (generate if needed for local/skip-infra modes)
    initialize_api_key

    # Start local orchestrator if requested (uses API_KEY)
    start_local_orchestrator

    # Load status.json for auto-resume
    enforce_status_config_match
    maybe_resume_from_status

    # Setup infrastructure - spawns meta terraform in pane
    setup_infrastructure

    # Generate run ID early so we can prepare provider terraform
    if test -z "$RUN_ID"
        set -g RUN_ID (generate_run_id)
        log_info "Generated run ID: $RUN_ID"
    else
        log_info "Using run ID: $RUN_ID"
    end

    # Determine providers and validate configuration
    set -l providers (configured_providers)

    if test (count $providers) -eq 0
        log_error "No providers configured in $CONFIG_FILE"
        exit 1
    end

    for provider in $providers
        provider_validate $provider
    end

    # Split providers into pre-orchestrator and post-run phases
    set -l pre_providers
    set -l post_providers
    for provider in $providers
        switch (provider_phase $provider)
            case pre_orchestrator
                set pre_providers $pre_providers $provider
            case post_run
                set post_providers $post_providers $provider
        end
    end

    # Wait for meta infrastructure terraform to complete (needed for provider config and orchestrator)
    wait_for_meta_infrastructure

    # Get orchestrator configuration
    get_orchestrator_config

    # Prepare and spawn cloud provider terraforms in panes
    # (Must happen after meta terraform completes since providers need its outputs)
    set -l provider_pane_ids
    set -l provider_names
    if test "$SKIP_INFRA" = true
        if test (count $pre_providers) -gt 0
            log_warning "Skipping cloud task runner provisioning due to --skip-infra"
        end
    else
        for provider in $pre_providers
            switch $provider
                case aws
                    if aws_task_runners_exist
                        if aws_run_id_matches "$RUN_ID"
                            log_info "AWS task runners already exist for run $RUN_ID; skipping apply"
                            show_existing_aws_task_runners
                            update_aws_status existing
                            continue
                        else
                            log_info "AWS task runners exist but run ID differs; recreating"
                        end
                    end

                    if prepare_aws_task_runners
                        set -l tf_dir (get_aws_terraform_dir)
                        set -l tf_cmd "terraform -chdir='$tf_dir' apply -auto-approve -parallelism=30"
                        set -l pane_id (tmux_spawn_pane "AWS Task Runners" "$tf_cmd")
                        set -a provider_pane_ids $pane_id
                        set -a provider_names aws
                        log_info "AWS terraform running in pane..."
                    end
                case azure
                    if azure_task_runners_exist
                        if azure_run_id_matches "$RUN_ID"
                            log_info "Azure task runners already exist for run $RUN_ID; skipping apply"
                            show_existing_azure_task_runners
                            update_azure_status existing
                            continue
                        else
                            log_info "Azure task runners exist but run ID differs; recreating"
                        end
                    end

                    if prepare_azure_task_runners
                        set -l tf_dir (get_azure_terraform_dir)
                        set -l tf_cmd "terraform -chdir='$tf_dir' apply -auto-approve -parallelism=30"
                        set -l pane_id (tmux_spawn_pane "Azure Task Runners" "$tf_cmd")
                        set -a provider_pane_ids $pane_id
                        set -a provider_names azure
                        log_info "Azure terraform running in pane..."
                    end
            end
        end
    end

    # Wait for orchestrator to be ready
    wait_for_orchestrator

    # Create or resume the benchmark run
    if test "$RESUME_RUN" = true
        log_info "Skipping run creation (resuming run $RUN_ID)"
    else
        create_run
    end

    status_set_run "$RUN_ID"

    # Start post-run providers (local)
    for provider in $post_providers
        provider_setup_task_runners $provider
    end

    # Wait for cloud provider terraform panes to complete
    for idx in (seq 1 (count $provider_pane_ids))
        set -l pane_id $provider_pane_ids[$idx]
        set -l provider $provider_names[$idx]
        log_info "Waiting for $provider terraform to complete..."
        tmux_wait_pane $pane_id
        set -l tf_status $status
        if test $tf_status -ne 0
            log_error "$provider terraform failed"
            exit 1
        end
        # Finalize provider (show outputs)
        switch $provider
            case aws
                finalize_aws_task_runners
                update_aws_status applied
            case azure
                finalize_azure_task_runners
                update_azure_status applied
        end
        log_success "$provider task runner setup completed"
    end

    # Monitor progress
    poll_run_status

    # Download results
    download_results

    # Clean up tmux temp files
    tmux_cleanup

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
