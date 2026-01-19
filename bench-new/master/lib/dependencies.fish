function check_dependencies
    log_info "Checking dependencies..."

    set -l missing_deps

    set -l base_deps jq curl
    if not set -q NON_INTERACTIVE; or test "$NON_INTERACTIVE" != true
        set base_deps $base_deps gum
    end

    for dep in $base_deps
        if not command -q $dep
            set missing_deps $missing_deps $dep
        end
    end

    if test "$LOCAL_ORCHESTRATOR" = true
        if not command -q docker
            set missing_deps $missing_deps docker
        end
    else if not test "$SKIP_INFRA" = true
        if not command -q terraform
            set missing_deps $missing_deps terraform
        end
    end

    if test (count $missing_deps) -gt 0
        log_error "Missing dependencies: $missing_deps"
        exit 1
    end

    log_success "All dependencies found"
end
