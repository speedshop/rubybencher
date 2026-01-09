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
