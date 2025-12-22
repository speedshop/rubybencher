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
