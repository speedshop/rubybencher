function parse_args
    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case -f --force -y --yes
                set -g FORCE true
            case --providers-only
                set -g PROVIDERS_ONLY true
            case --run-id
                set i (math $i + 1)
                if test $i -le (count $argv)
                    set -g TARGET_RUN_ID $argv[$i]
                else
                    log_error "--run-id requires a value"
                    exit 1
                end
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

    # Validate: providers-only and run-id are mutually exclusive
    if test "$PROVIDERS_ONLY" = true; and test -n "$TARGET_RUN_ID"
        log_error "--providers-only and --run-id cannot be used together"
        exit 1
    end
end
