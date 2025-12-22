#!/usr/bin/env fish
# Nuke Script - Destroy all benchmark infrastructure
# Cleans up AWS resources, terraform state, and local containers

set -g SCRIPT_DIR (dirname (status --current-filename))
set -g BENCH_DIR (dirname $SCRIPT_DIR)
set -g LIB_DIR "$SCRIPT_DIR/lib"

# Options
set -g FORCE false

source "$LIB_DIR/logging.fish"
source "$LIB_DIR/usage.fish"
source "$LIB_DIR/args.fish"
source "$LIB_DIR/terraform.fish"
source "$LIB_DIR/aws.fish"
source "$LIB_DIR/docker.fish"
source "$LIB_DIR/files.fish"

function confirm_destruction
    if test "$FORCE" = true
        return 0
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
        "This will destroy:" \
        "• All AWS infrastructure (EC2, VPC, S3)" \
        "• Terraform state" \
        "• Local Docker containers" \
        "" \
        "This action cannot be undone!"

    echo ""
    if not gum confirm --default=false "Are you sure you want to destroy all infrastructure?"
        log_info "Aborted"
        exit 0
    end

    # Double confirmation for safety
    echo ""
    set -l confirm_text (gum input --placeholder "Type 'destroy' to confirm")

    if test "$confirm_text" != "destroy"
        log_info "Confirmation failed - aborted"
        exit 0
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

    # Confirm destruction
    confirm_destruction

    echo ""
    log_info "Starting cleanup..."
    echo ""

    # Run cleanup steps
    set -l errors 0

    destroy_terraform
    or set errors (math $errors + 1)

    cleanup_aws_stragglers
    or set errors (math $errors + 1)

    cleanup_local_containers
    or set errors (math $errors + 1)

    cleanup_local_files
    or set errors (math $errors + 1)

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
            "All infrastructure destroyed."
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
