function cleanup_local_files
    log_info "Cleaning up local files..."

    # Clean terraform plan files
    find "$BENCH_DIR/infrastructure" -name "*.tfplan" -delete 2>/dev/null || true
    find "$BENCH_DIR/infrastructure" -name "tfplan" -delete 2>/dev/null || true

    # Clean AWS task runner tfvars (contains run-specific config)
    if test -f "$BENCH_DIR/infrastructure/aws/terraform.tfvars"
        rm -f "$BENCH_DIR/infrastructure/aws/terraform.tfvars"
        log_info "Removed AWS task runner terraform.tfvars"
    end

    # Clean Azure task runner tfvars (contains run-specific config)
    if test -f "$BENCH_DIR/infrastructure/azure/terraform.tfvars"
        rm -f "$BENCH_DIR/infrastructure/azure/terraform.tfvars"
        log_info "Removed Azure task runner terraform.tfvars"
    end

    # Optionally clean results
    if test -d "$BENCH_DIR/results"
        set -l result_count (ls -1 "$BENCH_DIR/results" 2>/dev/null | wc -l | string trim)

        if test "$result_count" -gt 0
            log_warning "Found $result_count result directories"

            if test "$FORCE" = true; or gum confirm "Delete all benchmark results?"
                rm -rf "$BENCH_DIR/results"/*
                log_success "Results deleted"
            end
        end
    end

    log_success "Local files cleaned"
end
