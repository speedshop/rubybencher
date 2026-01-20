function main
    # Parse command line arguments
    parse_args $argv

    # Display banner
    if set -q NON_INTERACTIVE; and test "$NON_INTERACTIVE" = true
        log_info "Ruby Cross Cloud Benchmark: master"
    else
        gum style \
            --border double \
            --align center \
            --width 50 \
            --margin "1" \
            --padding "1" \
            "Ruby Cross Cloud Benchmark" \
            "Master Script"
    end

    # Validate inputs and load config options
    validate_config
    load_config_options
    check_dependencies

    if test "$CLI_RESUME_RUN" = true; and test -z "$RESUME_RUN_TARGET"
        log_error "--resume-run requires a value (run ID or 'latest')"
        exit 1
    end

    # Show config summary
    echo ""
    log_info "Configuration ($CONFIG_FILE):"
    jq . "$CONFIG_FILE"
    echo ""

    # Set up signal handler
    trap cleanup_on_interrupt SIGINT SIGTERM

    # Initialize tmux pane tracking
    if not set -q NON_INTERACTIVE; or test "$NON_INTERACTIVE" != true
        tmux_init_pane_tracking
    end

    # Load orchestrator session if requested
    if test "$REUSE_ORCHESTRATOR" = true
        load_orchestrator_session
    end

    # Initialize API key (generate if needed for local/skip-infra modes)
    initialize_api_key

    # Start local orchestrator if requested (uses API_KEY)
    start_local_orchestrator

    # Resolve resume target if provided
    if test -n "$RESUME_RUN_TARGET"
        if test "$REUSE_ORCHESTRATOR" != true
            log_error "--resume-run requires --reuse-orchestrator"
            exit 1
        end

        set -l resolved_run_id (resolve_resume_run_id "$RESUME_RUN_TARGET")
        if test -z "$resolved_run_id"
            log_error "Unable to resolve resume target: $RESUME_RUN_TARGET"
            exit 1
        end

        if not run_status_exists "$resolved_run_id"
            log_error "Run status file not found for run $resolved_run_id"
            exit 1
        end

        set -g RUN_ID "$resolved_run_id"
        set -g RESUME_RUN true
        enforce_run_status_config_match "$RUN_ID"
        log_info "Resuming run $RUN_ID from status files"
    end

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

    # Prepare and run cloud provider terraforms
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
                        set -l tf_cmd terraform -chdir="$tf_dir" apply -auto-approve -parallelism=30

                        if set -q NON_INTERACTIVE; and test "$NON_INTERACTIVE" = true
                            log_info "Running AWS terraform apply..."
                            $tf_cmd
                            if test $status -ne 0
                                log_error "aws terraform failed"
                                exit 1
                            end
                            finalize_aws_task_runners
                            update_aws_status applied
                            log_success "aws task runner setup completed"
                        else
                            set -l pane_id (tmux_spawn_pane "AWS Task Runners" (string join ' ' $tf_cmd))
                            set -a provider_pane_ids $pane_id
                            set -a provider_names aws
                            log_info "AWS terraform running in pane..."
                        end
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
                        set -l tf_cmd terraform -chdir="$tf_dir" apply -auto-approve -parallelism=30

                        if set -q NON_INTERACTIVE; and test "$NON_INTERACTIVE" = true
                            log_info "Running Azure terraform apply..."
                            $tf_cmd
                            if test $status -ne 0
                                log_error "azure terraform failed"
                                exit 1
                            end
                            finalize_azure_task_runners
                            update_azure_status applied
                            log_success "azure task runner setup completed"
                        else
                            set -l pane_id (tmux_spawn_pane "Azure Task Runners" (string join ' ' $tf_cmd))
                            set -a provider_pane_ids $pane_id
                            set -a provider_names azure
                            log_info "Azure terraform running in pane..."
                        end
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

    if test "$RESUME_RUN" != true
        run_status_set "$RUN_ID"
    end

    # Start post-run providers (local)
    for provider in $post_providers
        provider_setup_task_runners $provider
    end

    # Wait for cloud provider terraform panes to complete
    if test (count $provider_pane_ids) -gt 0
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
    end


    # Monitor progress
    poll_run_status

    # Download results
    download_results
    set -l download_status $status

    # Clean up tmux temp files
    tmux_cleanup

    if set -q NON_INTERACTIVE; and test "$NON_INTERACTIVE" = true
        set -l run_response (curl -s "$ORCHESTRATOR_URL/runs/$RUN_ID" \
            -H "Authorization: Bearer $API_KEY")

        set -l final_status (echo $run_response | jq -r '.status // "unknown"')
        set -l total (echo $run_response | jq -r '.tasks.total // 0')
        set -l completed (echo $run_response | jq -r '.tasks.completed // 0')
        set -l failed (echo $run_response | jq -r '.tasks.failed // 0')

        set -l exit_code 0
        if test "$final_status" = "completed"
            if test $failed -gt 0
                set exit_code 2
            end
        else
            # cancelled/unknown => non-zero
            set exit_code 2
        end

        # If we couldn't fetch results but tasks were otherwise successful, fail the run.
        if test $download_status -ne 0; and test $exit_code -eq 0
            set exit_code 1
        end

        set -l status_file (run_status_file_path "$RUN_ID")
        set -l results_dir "$RESULTS_DIR/$RUN_ID"
        set -l dashboard_url "$ORCHESTRATOR_URL/runs/$RUN_ID"
        set -l now (date -u +"%Y-%m-%dT%H:%M:%SZ")

        run_status_update \
            '.updated_at = $updated_at |
             .orchestrator_url = $orchestrator_url |
             .dashboard_url = $dashboard_url |
             .results_dir = $results_dir |
             .run = { status: $status, tasks: { total: $total, completed: $completed, failed: $failed } }' \
            --arg updated_at "$now" \
            --arg orchestrator_url "$ORCHESTRATOR_URL" \
            --arg dashboard_url "$dashboard_url" \
            --arg results_dir "$results_dir" \
            --arg status "$final_status" \
            --argjson total $total \
            --argjson completed $completed \
            --argjson failed $failed

        # Machine-readable final line for agents/CI
        jq -nc \
            --arg run_id "$RUN_ID" \
            --arg orchestrator_url "$ORCHESTRATOR_URL" \
            --arg dashboard_url "$dashboard_url" \
            --arg status_file "$status_file" \
            --arg results_dir "$results_dir" \
            --arg status "$final_status" \
            --argjson total $total \
            --argjson completed $completed \
            --argjson failed $failed \
            --argjson exit_code $exit_code \
            '{run_id: $run_id, orchestrator_url: $orchestrator_url, dashboard_url: $dashboard_url, status_file: $status_file, results_dir: $results_dir, status: $status, tasks: {total: $total, completed: $completed, failed: $failed}, exit_code: $exit_code}'

        exit $exit_code
    end

    # Final summary (interactive)
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
        set -l cleanup_choice (gum choose \
            "Everything" \
            "Task runners for run $RUN_ID" \
            "Nothing")

        switch "$cleanup_choice"
            case "Everything"
                fish "$BENCH_DIR/nuke/nuke.fish" -f
            case "Task runners for run $RUN_ID"
                fish "$BENCH_DIR/nuke/nuke.fish" --run-id "$RUN_ID"
            case '*'
                log_info "Skipping cleanup"
        end
    end
end
