#!/usr/bin/env fish
# Nuke Script - Destroy benchmark infrastructure
# Supports tag-based cleanup with optional --run-id targeting
# Per NUKE_SPEC.md: idempotent, run-id-aware, ordered deletion

set -g SCRIPT_DIR (dirname (status --current-filename))
set -g BENCH_DIR (dirname $SCRIPT_DIR)
set -g LIB_DIR "$SCRIPT_DIR/lib"

# Options
set -g FORCE false
set -g TARGET_RUN_ID ""

source "$LIB_DIR/logging.fish"
source "$LIB_DIR/usage.fish"
source "$LIB_DIR/args.fish"
source "$LIB_DIR/terraform.fish"
source "$LIB_DIR/aws.fish"
source "$LIB_DIR/azure.fish"
source "$LIB_DIR/docker.fish"
source "$LIB_DIR/files.fish"

function confirm_destruction
    if test "$FORCE" = true
        return 0
    end

    set -l scope "ALL rb_managed resources"
    if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
        set scope "run ID: $TARGET_RUN_ID"
    end

    echo ""
    gum style \
        --border double \
        --border-foreground 196 \
        --align center \
        --width 60 \
        --padding "1" \
        --foreground 196 \
        "WARNING: DESTRUCTIVE OPERATION" \
        "" \
        "Target: $scope" \
        "" \
        "This will destroy:" \
        "• AWS infrastructure (EC2, VPC, S3)" \
        "• Azure infrastructure (VMs, VNet, NSG)" \
        "• Terraform state" \
        "• Local Docker containers" \
        "" \
        "This action cannot be undone!"

    echo ""
    if not gum confirm --default=false "Are you sure you want to destroy infrastructure?"
        log_info "Aborted"
        exit 0
    end

    # Double confirmation only for full cleanup (not targeted)
    if test -z "$TARGET_RUN_ID"
        echo ""
        set -l confirm_text (gum input --placeholder "Type 'destroy' to confirm FULL cleanup")

        if test "$confirm_text" != "destroy"
            log_info "Confirmation failed - aborted"
            exit 0
        end
    end
end

function main
    parse_args $argv

    # Display banner
    gum style \
        --border double \
        --border-foreground 196 \
        --align center \
        --width 50 \
        --margin "1" \
        --padding "1" \
        --foreground 196 \
        "Ruby Cross Cloud Benchmark" \
        "NUKE Script"

    # Show mode
    if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
        log_info "Mode: Targeted cleanup (run_id: $TARGET_RUN_ID)"
    else
        log_info "Mode: Full cleanup (ALL rb_managed resources)"
    end

    # Confirm destruction
    confirm_destruction

    echo ""
    log_info "Starting cleanup..."
    echo ""

    # Run cleanup steps
    set -l errors 0

    # Terraform-managed resources
    if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
        # Targeted mode: only destroy matching terraform state
        destroy_terraform_for_run "$TARGET_RUN_ID"
        or set errors (math $errors + 1)
    else
        # Full mode: destroy all terraform
        destroy_terraform
        or set errors (math $errors + 1)
    end

    # Tag-based cloud resource cleanup (handles stragglers)
    cleanup_aws_stragglers
    or set errors (math $errors + 1)

    cleanup_azure_resources
    or set errors (math $errors + 1)

    # Local cleanup only in full mode
    if test -z "$TARGET_RUN_ID"
        cleanup_local_containers
        or set errors (math $errors + 1)

        cleanup_local_files
        or set errors (math $errors + 1)
    end

    # Final summary
    echo ""
    if test $errors -eq 0
        gum style \
            --border rounded \
            --align center \
            --width 50 \
            --padding "1" \
            --foreground 82 \
            "Cleanup Complete!" \
            "All targeted infrastructure destroyed."
    else
        gum style \
            --border rounded \
            --align center \
            --width 50 \
            --padding "1" \
            --foreground 214 \
            "Cleanup completed with warnings" \
            "$errors step(s) had issues"
    end
end

# Run main
main $argv
