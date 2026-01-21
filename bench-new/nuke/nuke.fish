#!/usr/bin/env fish
# Nuke Script - Destroy benchmark infrastructure
# Supports tag-based cleanup with optional --run-id targeting
# Per NUKE_SPEC.md: idempotent, run-id-aware, ordered deletion

set -g SCRIPT_DIR (dirname (status --current-filename))
set -g BENCH_DIR (dirname $SCRIPT_DIR)
set -g LIB_DIR "$SCRIPT_DIR/lib"

# Options
set -g FORCE true
set -g TARGET_RUN_ID ""
set -g PROVIDERS_ONLY false
set -g THERMONUCLEAR false

source "$LIB_DIR/logging.fish"
source "$LIB_DIR/usage.fish"
source "$LIB_DIR/args.fish"
source "$LIB_DIR/terraform.fish"
source "$LIB_DIR/aws.fish"
source "$LIB_DIR/azure.fish"
source "$LIB_DIR/docker.fish"
source "$LIB_DIR/files.fish"

function confirm_destruction
    set -l skip_confirm false
    if test "$FORCE" = true
        set skip_confirm true
    end

    set -l scope "ALL rb_managed resources"
    if test "$THERMONUCLEAR" = true
        set scope "local state only (thermonuclear mode)"
    else if test "$PROVIDERS_ONLY" = true
        set scope "Provider infrastructure only (AWS/Azure)"
    else if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
        set scope "run ID: $TARGET_RUN_ID"
    end

    echo ""
    if test "$THERMONUCLEAR" = true
        gum style \
            --border double \
            --border-foreground 196 \
            --align center \
            --width 60 \
            --padding "1" \
            --foreground 196 \
            "⚠️  THERMONUCLEAR MODE ⚠️" \
            "" \
            "This will SKIP Terraform destroy and ONLY:" \
            "" \
            "• Delete local Terraform state files" \
            "• Cleanup tagged cloud stragglers" \
            "• Delete local Docker containers and files" \
            "" \
            "⚠️  CLOUD RESOURCES MAY REMAIN RUNNING  ⚠️" \
            "" \
            "You are responsible for manual cleanup of:" \
            "• EC2 instances, S3 buckets, VPCs" \
            "• Azure VMs, VNets, storage accounts" \
            "" \
            "Use this only when Terraform state is corrupt" \
            "or when cloud resources are already deleted."
    else if test "$PROVIDERS_ONLY" = true
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
            "• AWS infrastructure (EC2 instances)" \
            "• Azure infrastructure (VMs)" \
            "• Provider terraform state" \
            "" \
            "Orchestrator/meta infrastructure will be preserved." \
            "" \
            "This action cannot be undone!"
    else if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
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
            "This will destroy task runners and related cloud resources" \
            "for the specified run ID, plus matching terraform state." \
            "" \
            "This action cannot be undone!"
    else
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
    end

    if test "$skip_confirm" = true
        return 0
    end

    echo ""
    if test "$THERMONUCLEAR" = true
        if not gum confirm --default=false "Proceed with thermonuclear cleanup?"
            log_info "Aborted"
            exit 0
        end

        echo ""
        set -l confirm_text (gum input --placeholder "Type 'NUKE' to confirm thermonuclear mode")

        if test "$confirm_text" != "NUKE"
            log_info "Confirmation failed - aborted"
            exit 0
        end
    else
        if not gum confirm --default=false "Are you sure you want to destroy infrastructure?"
            log_info "Aborted"
            exit 0
        end
    end

    # Double confirmation only for full cleanup (not targeted or providers-only)
    if test -z "$TARGET_RUN_ID"; and test "$PROVIDERS_ONLY" != true; and test "$THERMONUCLEAR" != true
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
    if test "$THERMONUCLEAR" = true
        log_info "Mode: Thermonuclear (skip Terraform destroy, delete local state only)"
    else if test "$PROVIDERS_ONLY" = true
        log_info "Mode: Providers-only (AWS/Azure task runners)"
    else if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
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
    if test "$THERMONUCLEAR" = true
        # Thermonuclear mode: skip terraform destroy, delete local state only
        delete_terraform_state
        or set errors (math $errors + 1)
    else if test "$PROVIDERS_ONLY" = true
        # Providers-only mode: destroy only AWS/Azure terraform
        destroy_terraform_providers_only
        or set errors (math $errors + 1)
    else if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
        # Targeted mode: only destroy matching terraform state
        destroy_terraform_for_run "$TARGET_RUN_ID"
        or set errors (math $errors + 1)
    else
        # Full mode: destroy all terraform
        destroy_terraform
        or set errors (math $errors + 1)
    end

    # Tag-based cloud resource cleanup (handles stragglers)
    # Skip manual cleanup in providers-only mode (terraform handles it)
    if test "$PROVIDERS_ONLY" != true
        cleanup_aws_stragglers
        or set errors (math $errors + 1)

        cleanup_azure_resources
        or set errors (math $errors + 1)
    end

    # Local cleanup only in full mode or thermonuclear mode
    if test "$THERMONUCLEAR" = true; or test -z "$TARGET_RUN_ID"; and test "$PROVIDERS_ONLY" != true
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

    echo ""
    log_info "Cost report (last 30 days)"
    report_aws_costs_last_30_days
    report_azure_costs_last_30_days
end

# Run main
main $argv
