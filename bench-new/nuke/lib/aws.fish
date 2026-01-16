# AWS cleanup functions for nuke script
# Tag-based cleanup with ordered deletion per NUKE_SPEC.md

function get_tag_filters
    # Build AWS CLI filters based on mode
    # Returns multiple filter sets for comprehensive cleanup
    if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
        # Targeted mode: only new-style tags
        echo "Name=tag:rb_run_id,Values=$TARGET_RUN_ID"
    else
        # Full cleanup mode: catch both new and legacy resources
        # We return multiple filter patterns to be used separately
        echo "rb_managed"  # Signal to use multiple filter strategies
    end
end

function query_resources_with_fallback
    # Query resources using both new tags and legacy name prefix
    # $argv[1] = resource type (instances, vpcs, etc.)
    # $argv[2] = jq query path
    # $argv[3...] = additional filters (optional)
    set -l resource_type $argv[1]
    set -l query_path $argv[2]
    set -l extra_filters $argv[3..-1]

    set -l all_ids

    if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
        # Targeted mode: only new-style rb_run_id tag
        set -l result (aws ec2 describe-$resource_type \
            --filters "Name=tag:rb_run_id,Values=$TARGET_RUN_ID" $extra_filters \
            --query "$query_path" \
            --output text 2>/dev/null | string split \t)
        for id in $result
            if test -n "$id"
                set -a all_ids $id
            end
        end
    else
        # Full cleanup: use multiple strategies to catch all resources

        # Strategy 1: New rb_managed tag
        set -l result1 (aws ec2 describe-$resource_type \
            --filters "Name=tag:rb_managed,Values=true" $extra_filters \
            --query "$query_path" \
            --output text 2>/dev/null | string split \t)
        for id in $result1
            if test -n "$id"
                set -a all_ids $id
            end
        end

        # Strategy 2: Legacy Name tag prefix (railsbencher-*)
        set -l result2 (aws ec2 describe-$resource_type \
            --filters "Name=tag:Name,Values=railsbencher-*" $extra_filters \
            --query "$query_path" \
            --output text 2>/dev/null | string split \t)
        for id in $result2
            if test -n "$id"
                # Deduplicate
                if not contains $id $all_ids
                    set -a all_ids $id
                end
            end
        end

        # Strategy 3: Legacy RunId tag (any value)
        set -l result3 (aws ec2 describe-$resource_type \
            --filters "Name=tag-key,Values=RunId" $extra_filters \
            --query "$query_path" \
            --output text 2>/dev/null | string split \t)
        for id in $result3
            if test -n "$id"
                # Deduplicate
                if not contains $id $all_ids
                    set -a all_ids $id
                end
            end
        end
    end

    # Return unique IDs
    for id in $all_ids
        echo $id
    end
end

function cleanup_aws_instances
    log_info "Step 1: Terminating EC2 instances..."

    set -l valid_instances (query_resources_with_fallback \
        "instances" \
        "Reservations[].Instances[].InstanceId" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped")

    if test (count $valid_instances) -eq 0
        log_success "No EC2 instances to terminate"
        return 0
    end

    log_warning "Found instances: $valid_instances"

    if test "$FORCE" = true; or gum confirm "Terminate these instances?"
        for instance_id in $valid_instances
            log_info "Terminating: $instance_id"
            aws ec2 terminate-instances --instance-ids "$instance_id" 2>/dev/null || true
        end

        # Wait for instances to terminate
        log_info "Waiting for instances to terminate..."
        for instance_id in $valid_instances
            aws ec2 wait instance-terminated --instance-ids "$instance_id" 2>/dev/null || true
        end
        log_success "Instances terminated"
    end
end

function cleanup_aws_enis
    log_info "Step 2: Detaching and deleting ENIs..."

    set -l valid_enis (query_resources_with_fallback \
        "network-interfaces" \
        "NetworkInterfaces[].NetworkInterfaceId")

    if test (count $valid_enis) -eq 0
        log_success "No ENIs to delete"
        return 0
    end

    log_warning "Found ENIs: $valid_enis"

    if test "$FORCE" = true; or gum confirm "Delete these ENIs?"
        for eni_id in $valid_enis
            # Get attachment ID if attached
            set -l attachment_id (aws ec2 describe-network-interfaces \
                --network-interface-ids "$eni_id" \
                --query "NetworkInterfaces[0].Attachment.AttachmentId" \
                --output text 2>/dev/null)

            if test -n "$attachment_id"; and test "$attachment_id" != "None"
                log_info "Detaching ENI: $eni_id"
                aws ec2 detach-network-interface --attachment-id "$attachment_id" --force 2>/dev/null || true
                sleep 2
            end

            log_info "Deleting ENI: $eni_id"
            aws ec2 delete-network-interface --network-interface-id "$eni_id" 2>/dev/null || true
        end
        log_success "ENIs deleted"
    end
end

function cleanup_aws_eips
    log_info "Step 3: Releasing Elastic IPs..."

    # EIPs use describe-addresses, not describe-eips
    # query_resources_with_fallback doesn't work here, use direct queries
    set -l valid_eips

    if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
        set -l result (aws ec2 describe-addresses \
            --filters "Name=tag:rb_run_id,Values=$TARGET_RUN_ID" \
            --query "Addresses[].AllocationId" \
            --output text 2>/dev/null | string split \t)
        for eip in $result
            if test -n "$eip"
                set -a valid_eips $eip
            end
        end
    else
        # Full cleanup: multiple strategies
        for filter in "Name=tag:rb_managed,Values=true" "Name=tag:Name,Values=railsbencher-*" "Name=tag-key,Values=RunId"
            set -l result (aws ec2 describe-addresses \
                --filters "$filter" \
                --query "Addresses[].AllocationId" \
                --output text 2>/dev/null | string split \t)
            for eip in $result
                if test -n "$eip"; and not contains $eip $valid_eips
                    set -a valid_eips $eip
                end
            end
        end
    end

    if test (count $valid_eips) -eq 0
        log_success "No EIPs to release"
        return 0
    end

    log_warning "Found EIPs: $valid_eips"

    if test "$FORCE" = true; or gum confirm "Release these EIPs?"
        for alloc_id in $valid_eips
            log_info "Releasing EIP: $alloc_id"
            aws ec2 release-address --allocation-id "$alloc_id" 2>/dev/null || true
        end
        log_success "EIPs released"
    end
end

function cleanup_aws_security_groups
    log_info "Step 5: Deleting security groups..."

    set -l valid_sgs (query_resources_with_fallback \
        "security-groups" \
        "SecurityGroups[?GroupName != 'default'].GroupId")

    if test (count $valid_sgs) -eq 0
        log_success "No security groups to delete"
        return 0
    end

    log_warning "Found security groups: $valid_sgs"

    if test "$FORCE" = true; or gum confirm "Delete these security groups?"
        for sg_id in $valid_sgs
            log_info "Deleting security group: $sg_id"
            aws ec2 delete-security-group --group-id "$sg_id" 2>/dev/null || true
        end
        log_success "Security groups deleted"
    end
end

function cleanup_aws_subnets
    log_info "Step 6: Deleting subnets..."

    set -l valid_subnets (query_resources_with_fallback \
        "subnets" \
        "Subnets[].SubnetId")

    if test (count $valid_subnets) -eq 0
        log_success "No subnets to delete"
        return 0
    end

    log_warning "Found subnets: $valid_subnets"

    if test "$FORCE" = true; or gum confirm "Delete these subnets?"
        for subnet_id in $valid_subnets
            log_info "Deleting subnet: $subnet_id"
            aws ec2 delete-subnet --subnet-id "$subnet_id" 2>/dev/null || true
        end
        log_success "Subnets deleted"
    end
end

function cleanup_aws_internet_gateways
    log_info "Step 7: Deleting internet gateways..."

    set -l valid_igws (query_resources_with_fallback \
        "internet-gateways" \
        "InternetGateways[].InternetGatewayId")

    if test (count $valid_igws) -eq 0
        log_success "No internet gateways to delete"
        return 0
    end

    log_warning "Found internet gateways: $valid_igws"

    if test "$FORCE" = true; or gum confirm "Delete these internet gateways?"
        for igw_id in $valid_igws
            # Get attached VPC
            set -l vpc_id (aws ec2 describe-internet-gateways \
                --internet-gateway-ids "$igw_id" \
                --query "InternetGateways[0].Attachments[0].VpcId" \
                --output text 2>/dev/null)

            if test -n "$vpc_id"; and test "$vpc_id" != "None"
                log_info "Detaching IGW $igw_id from VPC $vpc_id"
                aws ec2 detach-internet-gateway \
                    --internet-gateway-id "$igw_id" \
                    --vpc-id "$vpc_id" 2>/dev/null || true
            end

            log_info "Deleting internet gateway: $igw_id"
            aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id" 2>/dev/null || true
        end
        log_success "Internet gateways deleted"
    end
end

function cleanup_aws_route_tables
    log_info "Step 8: Deleting route tables..."

    set -l valid_rts (query_resources_with_fallback \
        "route-tables" \
        "RouteTables[?Associations[0].Main != \`true\`].RouteTableId")

    if test (count $valid_rts) -eq 0
        log_success "No route tables to delete"
        return 0
    end

    log_warning "Found route tables: $valid_rts"

    if test "$FORCE" = true; or gum confirm "Delete these route tables?"
        for rt_id in $valid_rts
            # Disassociate from subnets first
            set -l assoc_ids (aws ec2 describe-route-tables \
                --route-table-ids "$rt_id" \
                --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" \
                --output text 2>/dev/null | string split \t)

            for assoc_id in $assoc_ids
                if test -n "$assoc_id"
                    aws ec2 disassociate-route-table --association-id "$assoc_id" 2>/dev/null || true
                end
            end

            log_info "Deleting route table: $rt_id"
            aws ec2 delete-route-table --route-table-id "$rt_id" 2>/dev/null || true
        end
        log_success "Route tables deleted"
    end
end

function cleanup_aws_vpcs
    log_info "Step 9: Deleting VPCs..."

    set -l valid_vpcs (query_resources_with_fallback \
        "vpcs" \
        "Vpcs[].VpcId")

    if test (count $valid_vpcs) -eq 0
        log_success "No VPCs to delete"
        return 0
    end

    log_warning "Found VPCs: $valid_vpcs"

    if test "$FORCE" = true; or gum confirm "Delete these VPCs?"
        for vpc_id in $valid_vpcs
            log_info "Deleting VPC: $vpc_id"
            aws ec2 delete-vpc --vpc-id "$vpc_id" 2>/dev/null || true
        end
        log_success "VPCs deleted"
    end
end

function cleanup_aws_s3_buckets
    log_info "Step 10: Deleting S3 buckets..."

    # S3 buckets don't support tag-based filtering in list-buckets
    # Must list all and check tags individually
    set -l all_buckets (aws s3api list-buckets \
        --query "Buckets[?starts_with(Name, 'railsbencher-')].Name" \
        --output text 2>/dev/null | string split \t)

    set -l matching_buckets
    for bucket in $all_buckets
        if test -n "$bucket"
            set -l tags (aws s3api get-bucket-tagging --bucket "$bucket" 2>/dev/null)

            if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
                # Targeted mode: match new rb_run_id tag
                if test -n "$tags"
                    set -l bucket_run_id (echo $tags | jq -r '.TagSet[] | select(.Key == "rb_run_id") | .Value' 2>/dev/null)
                    if test "$bucket_run_id" = "$TARGET_RUN_ID"
                        set -a matching_buckets $bucket
                    end
                end
            else
                # Full cleanup: match any railsbencher bucket
                # Check for rb_managed=true OR legacy RunId tag OR just the name prefix
                set -l should_delete false

                if test -n "$tags"
                    set -l is_managed (echo $tags | jq -r '.TagSet[] | select(.Key == "rb_managed") | .Value' 2>/dev/null)
                    set -l has_run_id (echo $tags | jq -r '.TagSet[] | select(.Key == "RunId") | .Value' 2>/dev/null)

                    if test "$is_managed" = "true"; or test -n "$has_run_id"
                        set should_delete true
                    end
                else
                    # No tags but has railsbencher- prefix - assume it's ours
                    set should_delete true
                end

                if test "$should_delete" = true
                    set -a matching_buckets $bucket
                end
            end
        end
    end

    if test (count $matching_buckets) -eq 0
        log_success "No S3 buckets to delete"
        return 0
    end

    log_warning "Found S3 buckets: $matching_buckets"

    if test "$FORCE" = true; or gum confirm "Delete these S3 buckets and contents?"
        for bucket in $matching_buckets
            log_info "Emptying bucket: $bucket"
            aws s3 rm "s3://$bucket" --recursive 2>/dev/null || true

            log_info "Deleting bucket: $bucket"
            aws s3api delete-bucket --bucket "$bucket" 2>/dev/null || true
        end
        log_success "S3 buckets deleted"
    end
end

function cleanup_aws_stragglers
    if not command -q aws
        log_warning "AWS CLI not found - skipping AWS cleanup"
        return 0
    end

    if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
        log_info "Cleaning up AWS resources for run: $TARGET_RUN_ID"
    else
        log_info "Cleaning up ALL rb_managed AWS resources..."
    end

    # Execute in order per NUKE_SPEC.md
    cleanup_aws_instances
    cleanup_aws_enis
    cleanup_aws_eips
    # Step 4: Load balancers/target groups - not used currently
    cleanup_aws_security_groups
    cleanup_aws_subnets
    cleanup_aws_internet_gateways
    cleanup_aws_route_tables
    cleanup_aws_vpcs
    cleanup_aws_s3_buckets
end

function report_aws_costs_last_30_days
    if not command -q aws
        log_warning "AWS CLI not found - skipping AWS cost report"
        return 0
    end

    set -l end_date (date -u +"%Y-%m-%d")
    set -l start_date ""

    if date -u -v -30d +"%Y-%m-%d" >/dev/null 2>&1
        set start_date (date -u -v -30d +"%Y-%m-%d")
    else
        set start_date (date -u -d "30 days ago" +"%Y-%m-%d")
    end

    set -l amounts (aws ce get-cost-and-usage \
        --time-period Start=$start_date,End=$end_date \
        --granularity DAILY \
        --metrics "UnblendedCost" \
        --query "ResultsByTime[].Total.UnblendedCost.Amount" \
        --output text 2>/dev/null)

    if test $status -ne 0; or test -z "$amounts"
        log_warning "AWS cost report unavailable (Cost Explorer not enabled or credentials missing)"
        return 0
    end

    set -l total 0
    for amount in $amounts
        if test -n "$amount"
            set total (math "$total + $amount")
        end
    end

    set -l unit (aws ce get-cost-and-usage \
        --time-period Start=$start_date,End=$end_date \
        --granularity DAILY \
        --metrics "UnblendedCost" \
        --query "ResultsByTime[0].Total.UnblendedCost.Unit" \
        --output text 2>/dev/null)

    if test -z "$unit"; or test "$unit" = "None"
        set unit "USD"
    end

    set -l total_formatted (printf "%.2f" $total)
    log_info "AWS last 30 days spend: $total_formatted $unit (unblended)"
end
