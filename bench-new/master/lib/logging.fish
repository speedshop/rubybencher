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
