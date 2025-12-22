function log_info
    gum log -l info $argv
end

function log_success
    gum log -l info --prefix "OK" $argv
end

function log_warning
    gum log -l warn $argv
end

function log_error
    gum log -l error $argv
end
