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
