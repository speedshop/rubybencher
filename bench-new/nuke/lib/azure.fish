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
