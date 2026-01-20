# Azure cleanup functions for nuke script
# Uses resource group deletion for efficient cleanup

function cleanup_azure_resources
    if not command -q az
        log_warning "Azure CLI not found - skipping Azure cleanup"
        return 0
    end

    # Check if logged in
    if not az account show >/dev/null 2>&1
        log_warning "Azure CLI not logged in - skipping Azure cleanup"
        return 0
    end

    if set -q TARGET_RUN_ID; and test -n "$TARGET_RUN_ID"
        # Delete specific resource group
        set -l rg_name "railsbencher-$TARGET_RUN_ID"

        set -l exists (az group exists --name "$rg_name" 2>/dev/null)
        if test "$exists" = "true"
            log_warning "Found Azure resource group: $rg_name"

            if test "$FORCE" = true; or gum confirm "Delete resource group $rg_name?"
                log_info "Deleting resource group: $rg_name"
                az group delete --name "$rg_name" --yes --no-wait 2>/dev/null || true
                log_success "Resource group deletion initiated"
            end
        else
            log_success "No Azure resource group for run $TARGET_RUN_ID"
        end
    else
        # Delete all railsbencher- resource groups
        set -l rgs (az group list --query "[?starts_with(name, 'railsbencher-')].name" -o tsv 2>/dev/null | string split \n)

        # Filter out empty strings
        set -l valid_rgs
        for rg in $rgs
            if test -n "$rg"
                set -a valid_rgs $rg
            end
        end

        if test (count $valid_rgs) -eq 0
            log_success "No Azure resource groups to delete"
            return 0
        end

        log_warning "Found Azure resource groups: $valid_rgs"

        if test "$FORCE" = true; or gum confirm "Delete these resource groups?"
            for rg in $valid_rgs
                log_info "Deleting resource group: $rg"
                az group delete --name "$rg" --yes --no-wait 2>/dev/null || true
            end
            log_success "Resource group deletions initiated"
        end
    end
end

function report_azure_costs_last_30_days
    if not command -q az
        log_warning "Azure CLI not found - skipping Azure cost report"
        return 0
    end

    if not az account show >/dev/null 2>&1
        log_warning "Azure CLI not logged in - skipping Azure cost report"
        return 0
    end

    set -l subscription_id (az account show --query id -o tsv 2>/dev/null)
    if test -z "$subscription_id"
        log_warning "Azure subscription ID not found - skipping Azure cost report"
        return 0
    end

    set -l end_date (date -u +"%Y-%m-%d")
    set -l start_date ""

    if date -u -v -30d +"%Y-%m-%d" >/dev/null 2>&1
        set start_date (date -u -v -30d +"%Y-%m-%d")
    else
        set start_date (date -u -d "30 days ago" +"%Y-%m-%d")
    end

    set -l payload (printf '{"type":"ActualCost","timeframe":"Custom","timePeriod":{"from":"%s","to":"%s"},"dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"Cost","function":"Sum"}}}}' "$start_date" "$end_date")
    set -l scope "/subscriptions/$subscription_id"

    set -l row (az rest \
        --method post \
        --uri "https://management.azure.com$scope/providers/Microsoft.CostManagement/query?api-version=2023-03-01" \
        --body "$payload" \
        --query "properties.rows[0]" \
        -o tsv 2>/dev/null)

    if test $status -ne 0; or test -z "$row"
        log_warning "Azure cost report unavailable (Cost Management access missing)"
        return 0
    end

    set -l fields (string split "\t" -- $row)
    set -l total $fields[1]
    set -l currency $fields[2]

    if test -z "$total"
        log_warning "Azure cost report unavailable (no cost data returned)"
        return 0
    end

    if test -z "$currency"
        set currency "USD"
    end

    set -l total_formatted (printf "%.2f" $total)
    log_info "Azure last 30 days spend: $total_formatted $currency"
end
