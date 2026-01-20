function main
    # Parse command line arguments
    parse_args $argv

    setup_logging

    # Display banner
    log_info "Ruby Cross Cloud Benchmark: master"

    # Validate inputs and load config options
    validate_config
    load_config_options
    check_dependencies

    if test "$CLI_RESUME_RUN" = true; and test -z "$RESUME_RUN_TARGET"
        log_error "--resume-run requires a value (run ID or 'latest')"
        exit 1
    end


    # Set up signal handler
    trap cleanup_on_interrupt SIGINT SIGTERM

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

    # Generate run ID early so we can prepare provider terraform
    if test -z "$RUN_ID"
        set -g RUN_ID (generate_run_id)
        ensure_run_log_dir
        log_info "Generated run ID: $RUN_ID"
    else
        ensure_run_log_dir
        log_info "Using run ID: $RUN_ID"
    end

    if set -q LOG_RUN_DIR; and test -n "$LOG_RUN_DIR"
        log_info "Run logs: $LOG_RUN_DIR"
    end

    # Show config summary
    echo ""
    log_info "Configuration ($CONFIG_FILE):"
    set -l config_log_targets (log_targets_for "")
    if test (count $config_log_targets) -gt 0
        jq . "$CONFIG_FILE" | tee -a $config_log_targets
    else
        jq . "$CONFIG_FILE"
    end
    echo ""

    # Setup infrastructure
    setup_infrastructure

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

    # Get orchestrator configuration
    get_orchestrator_config

    # Prepare and run cloud provider terraforms
    # (Must happen after meta terraform completes since providers need its outputs)
    set -l provider_job_pids
    set -l provider_job_names
    set -l provider_job_logs
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
                        set -l tf_log_file "$AWS_TF_LOG_FILE"

                        set -l job_pid (run_logged_command_bg "$tf_log_file" $tf_cmd)
                        set -a provider_job_pids $job_pid
                        set -a provider_job_names aws
                        set -a provider_job_logs $tf_log_file
                        log_info "AWS terraform running in background (pid $job_pid)"

                        if test -n "$tf_log_file"
                            log_info "AWS terraform log: $tf_log_file"
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
                        set -l tf_log_file "$AZURE_TF_LOG_FILE"

                        set -l job_pid (run_logged_command_bg "$tf_log_file" $tf_cmd)
                        set -a provider_job_pids $job_pid
                        set -a provider_job_names azure
                        set -a provider_job_logs $tf_log_file
                        log_info "Azure terraform running in background (pid $job_pid)"

                        if test -n "$tf_log_file"
                            log_info "Azure terraform log: $tf_log_file"
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
    if test (count $provider_job_pids) -gt 0
        for idx in (seq 1 (count $provider_job_pids))
            set -l job_pid $provider_job_pids[$idx]
            set -l provider $provider_job_names[$idx]
            set -l log_file $provider_job_logs[$idx]
            log_info "Waiting for $provider terraform to complete..."
            wait $job_pid
            set -l tf_status $status
            if test $tf_status -ne 0
                log_error "$provider terraform failed"
                if test -n "$log_file"
                    log_error "See $log_file for details"
                end
                exit 1
            end
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
