function log_info
    if set -q NON_INTERACTIVE; and test "$NON_INTERACTIVE" = true
        echo "INFO: $argv"
        return 0
    end

    gum style --foreground 212 "→ $argv"
end

function log_success
    if set -q NON_INTERACTIVE; and test "$NON_INTERACTIVE" = true
        echo "OK: $argv"
        return 0
    end

    gum style --foreground 82 "✓ $argv"
end

function log_error
    if set -q NON_INTERACTIVE; and test "$NON_INTERACTIVE" = true
        echo "ERROR: $argv" 1>&2
        return 0
    end

    gum style --foreground 196 "✗ $argv"
end

function log_warning
    if set -q NON_INTERACTIVE; and test "$NON_INTERACTIVE" = true
        echo "WARN: $argv"
        return 0
    end

    gum style --foreground 214 "⚠ $argv"
end
