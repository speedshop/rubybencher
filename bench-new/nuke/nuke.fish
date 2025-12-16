#!/usr/bin/env fish
# Nuke Script - Destroy all benchmark infrastructure
# Cleans up AWS resources, terraform state, and local containers

set -g SCRIPT_DIR (dirname (status --current-filename))
set -g BENCH_DIR (dirname $SCRIPT_DIR)

# Options
set -g FORCE false

function print_usage
    echo "Usage: nuke.fish [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -f, --force, -y, --yes    Skip confirmation prompts"
    echo "  -h, --help                Show this help"
    echo ""
    echo "Examples:"
    echo "  nuke.fish             Interactive cleanup with confirmations"
    echo "  nuke.fish --force     Destroy everything without prompts"
end

function log_info
    gum style --foreground 212 "→ $argv"
end

function log_success
    gum style --foreground 82 "✓ $argv"
end

function log_error
    gum style --foreground 196 "✗ $argv"
end

function log_warning
    gum style --foreground 214 "⚠ $argv"
end

function parse_args
    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case -f --force -y --yes
                set -g FORCE true
            case -h --help
                print_usage
                exit 0
            case '*'
                log_error "Unknown option: $argv[$i]"
                print_usage
                exit 1
        end
        set i (math $i + 1)
    end
end

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

function destroy_terraform
    set -l tf_dir "$BENCH_DIR/infrastructure/meta"

    if not test -d "$tf_dir"
        log_warning "Terraform directory not found: $tf_dir"
        return 0
    end

    if not test -d "$tf_dir/.terraform"
        log_warning "Terraform not initialized in $tf_dir"
        return 0
    end

    # Check if there's any state to destroy
    set -l state_list (terraform -chdir="$tf_dir" state list 2>/dev/null)
    if test -z "$state_list"
        log_info "No terraform state found - nothing to destroy"
        return 0
    end

    log_info "Destroying terraform-managed infrastructure..."

    # Show what will be destroyed
    echo ""
    gum spin --spinner dot --title "Planning destruction..." -- \
        terraform -chdir="$tf_dir" plan -destroy -out=destroy.tfplan

    if test "$FORCE" != true
        echo ""
        if not gum confirm "Proceed with terraform destroy?"
            log_info "Terraform destroy skipped"
            return 0
        end
    end

    # Execute destroy
    gum spin --spinner dot --title "Destroying AWS resources..." -- \
        terraform -chdir="$tf_dir" apply -auto-approve destroy.tfplan

    set -l destroy_status $status

    rm -f "$tf_dir/destroy.tfplan"

    if test $destroy_status -ne 0
        log_error "Terraform destroy failed"
        return 1
    end

    log_success "Terraform resources destroyed"
end

function cleanup_aws_stragglers
    if not command -q aws
        log_warning "AWS CLI not found - skipping straggler cleanup"
        return 0
    end

    log_info "Checking for straggler AWS resources..."

    # Check for running EC2 instances with our tag
    set -l instances (aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=railsbencher-*" "Name=instance-state-name,Values=running,pending,stopping" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text 2>/dev/null)

    if test -n "$instances"
        log_warning "Found straggler EC2 instances: $instances"

        if test "$FORCE" = true; or gum confirm "Terminate these instances?"
            for instance_id in (string split \t $instances)
                if test -n "$instance_id"
                    log_info "Terminating instance: $instance_id"
                    aws ec2 terminate-instances --instance-ids "$instance_id" 2>/dev/null
                end
            end
            log_success "Straggler instances terminated"
        end
    else
        log_success "No straggler EC2 instances found"
    end

    # Check for S3 buckets with our prefix
    log_info "Checking for S3 buckets..."

    set -l buckets (aws s3api list-buckets \
        --query "Buckets[?starts_with(Name, 'railsbencher-results')].Name" \
        --output text 2>/dev/null)

    if test -n "$buckets"
        log_warning "Found S3 buckets: $buckets"

        if test "$FORCE" = true; or gum confirm "Delete these S3 buckets and their contents?"
            for bucket in (string split \t $buckets)
                if test -n "$bucket"
                    log_info "Emptying bucket: $bucket"
                    aws s3 rm "s3://$bucket" --recursive 2>/dev/null || true

                    log_info "Deleting bucket: $bucket"
                    aws s3api delete-bucket --bucket "$bucket" 2>/dev/null || true
                end
            end
            log_success "S3 buckets deleted"
        end
    else
        log_success "No straggler S3 buckets found"
    end

    # Check for VPCs with our tag
    log_info "Checking for orphaned VPCs..."

    set -l vpcs (aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=railsbencher-*" \
        --query "Vpcs[].VpcId" \
        --output text 2>/dev/null)

    if test -n "$vpcs"
        log_warning "Found orphaned VPCs: $vpcs"
        log_info "These should have been cleaned up by terraform."
        log_info "You may need to manually delete them in the AWS console."
        log_info "Make sure to delete associated subnets, route tables, and internet gateways first."
    else
        log_success "No orphaned VPCs found"
    end
end

function cleanup_local_containers
    if not command -q docker
        log_warning "Docker not found - skipping local cleanup"
        return 0
    end

    log_info "Cleaning up local Docker resources..."

    # Stop orchestrator containers
    set -l orchestrator_dir "$BENCH_DIR/orchestrator"

    if test -f "$orchestrator_dir/docker-compose.yml"
        log_info "Stopping orchestrator containers..."

        cd "$orchestrator_dir"
        docker compose down -v 2>/dev/null || true
        cd -

        log_success "Orchestrator containers stopped"
    end

    # Stop any task runner containers
    log_info "Stopping task runner containers..."

    set -l task_containers (docker ps -aq --filter "name=task-runner-local-" 2>/dev/null)

    if test -n "$task_containers"
        docker rm -f $task_containers 2>/dev/null || true
        log_success "Task runner containers stopped"
    else
        log_success "No task runner containers found"
    end

    # Clean up dangling images (always)
    log_info "Removing dangling Docker images..."
    docker image prune -f 2>/dev/null || true
    log_success "Dangling images removed"
end

function cleanup_local_files
    log_info "Cleaning up local files..."

    # Clean terraform plan files
    find "$BENCH_DIR/infrastructure" -name "*.tfplan" -delete 2>/dev/null || true
    find "$BENCH_DIR/infrastructure" -name "tfplan" -delete 2>/dev/null || true

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
