function destroy_terraform_dir
    set -l tf_dir $argv[1]
    set -l dir_name $argv[2]

    if not test -d "$tf_dir"
        log_warning "Terraform directory not found: $tf_dir"
        return 0
    end

    if not test -d "$tf_dir/.terraform"
        log_warning "Terraform not initialized in $tf_dir"
        return 0
    end

    # Check for tfvars file - required for destroy to work without prompts
    if not test -f "$tf_dir/terraform.tfvars"
        log_info "No terraform.tfvars in $dir_name - nothing to destroy"
        return 0
    end

    log_info "Destroying $dir_name terraform-managed infrastructure..."

    if test "$FORCE" != true
        # Show plan for non-forced destroys
        terraform -chdir="$tf_dir" plan -destroy

        echo ""
        if not gum confirm "Proceed with terraform destroy for $dir_name?"
            log_info "Terraform destroy skipped for $dir_name"
            return 0
        end
    end

    # Execute destroy
    log_info "Destroying $dir_name resources..."
    terraform -chdir="$tf_dir" destroy -auto-approve -parallelism=30

    if test $status -ne 0
        log_error "Terraform destroy failed for $dir_name"
        return 1
    end

    log_success "$dir_name terraform resources destroyed"
end

function destroy_terraform
    # Destroy cloud task runner infrastructure first (depends on meta)
    destroy_terraform_dir "$BENCH_DIR/infrastructure/aws" "AWS task runners"

    # Destroy Azure task runner infrastructure
    destroy_terraform_dir "$BENCH_DIR/infrastructure/azure" "Azure task runners"

    # Then destroy meta infrastructure
    destroy_terraform_dir "$BENCH_DIR/infrastructure/meta" "meta"
end

function destroy_terraform_for_run
    # Destroy only terraform managed resources for a specific run_id
    # Meta infrastructure is NEVER destroyed in targeted mode
    set -l target_run_id $argv[1]

    log_info "Checking Terraform state for run $target_run_id..."

    # Check AWS terraform state for matching run_id
    set -l aws_tf_dir "$BENCH_DIR/infrastructure/aws"
    if test -f "$aws_tf_dir/terraform.tfstate"; or test -d "$aws_tf_dir/.terraform"
        if test -d "$aws_tf_dir/.terraform"
            set -l state_run_id (terraform -chdir="$aws_tf_dir" output -raw run_id 2>/dev/null)
            if test "$state_run_id" = "$target_run_id"
                log_info "AWS terraform state matches run $target_run_id - destroying..."
                destroy_terraform_dir "$aws_tf_dir" "AWS task runners"
            else if test -n "$state_run_id"
                log_info "AWS terraform state is for run $state_run_id, not $target_run_id - skipping"
            else
                log_info "No AWS terraform state found"
            end
        end
    else
        log_info "No AWS terraform infrastructure found"
    end

    # Check Azure terraform state for matching run_id
    set -l azure_tf_dir "$BENCH_DIR/infrastructure/azure"
    if test -f "$azure_tf_dir/terraform.tfstate"; or test -d "$azure_tf_dir/.terraform"
        if test -d "$azure_tf_dir/.terraform"
            set -l state_run_id (terraform -chdir="$azure_tf_dir" output -raw run_id 2>/dev/null)
            if test "$state_run_id" = "$target_run_id"
                log_info "Azure terraform state matches run $target_run_id - destroying..."
                destroy_terraform_dir "$azure_tf_dir" "Azure task runners"
            else if test -n "$state_run_id"
                log_info "Azure terraform state is for run $state_run_id, not $target_run_id - skipping"
            else
                log_info "No Azure terraform state found"
            end
        end
    else
        log_info "No Azure terraform infrastructure found"
    end

    # NOTE: Meta infrastructure is NEVER destroyed in targeted mode
    log_info "Meta infrastructure preserved (shared across runs)"
end
