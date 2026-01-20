function setup_infrastructure
    if test "$SKIP_INFRA" = true
        log_warning "Skipping infrastructure setup (--skip-infra)"
        return 0
    end

    if test "$LOCAL_ORCHESTRATOR" = true
        # Local orchestrator is handled separately
        return 0
    end

    if test "$REUSE_ORCHESTRATOR" = true
        log_info "Reusing existing meta infrastructure from orchestrator.json"
        return 0
    end

    log_info "Setting up meta-infrastructure on AWS (orchestrator, bastion, S3, networking)..."

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

    # Pass AWS credentials from environment to Terraform
    if set -q AWS_ACCESS_KEY_ID
        set -gx TF_VAR_aws_access_key_id "$AWS_ACCESS_KEY_ID"
    end
    if set -q AWS_SECRET_ACCESS_KEY
        set -gx TF_VAR_aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
    end

    # Validate AWS credentials are available
    if not set -q TF_VAR_aws_access_key_id; or test -z "$TF_VAR_aws_access_key_id"
        log_error "AWS credentials required. Set AWS_ACCESS_KEY_ID environment variable."
        exit 1
    end
    if not set -q TF_VAR_aws_secret_access_key; or test -z "$TF_VAR_aws_secret_access_key"
        log_error "AWS credentials required. Set AWS_SECRET_ACCESS_KEY environment variable."
        exit 1
    end

    set -g META_TF_LOG_FILE (log_path_for "meta-terraform")

    # Initialize terraform if needed
    if not test -d "$tf_dir/.terraform"
        set -l init_cmd (wrap_command_with_logging "$META_TF_LOG_FILE" terraform -chdir="$tf_dir" init)
        run_with_spinner "Initializing meta Terraform..." fish -c "$init_cmd"
        if test $status -ne 0
            log_error "Meta terraform init failed"
            exit 1
        end
    end

    set -l tf_cmd terraform -chdir="$tf_dir" apply -auto-approve -parallelism=30
    set -l tf_log_file "$META_TF_LOG_FILE"

    log_info "Running meta terraform apply..."
    if test -n "$tf_log_file"
        log_info "Meta terraform log: $tf_log_file"
    end
    run_logged_command "$tf_log_file" $tf_cmd
    if test $status -ne 0
        log_error "Meta infrastructure terraform failed"
        if test -n "$tf_log_file"
            log_error "See $tf_log_file for details"
        end
        exit 1
    end
    log_success "Meta infrastructure ready"
    return 0
end

