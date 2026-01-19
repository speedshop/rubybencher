function generate_api_key
    # Generate a random 32-character hex string
    if command -q openssl
        openssl rand -hex 16
    else
        cat /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | head -c 32
    end
end

function generate_run_id
    # Generate a run ID matching the server format: timestamp + 8 random digits
    set -l timestamp (date +%s)
    set -l random_digits (printf "%08d" (math (random) % 100000000))
    echo "$timestamp$random_digits"
end

function run_with_spinner
    set -l title $argv[1]
    set -l cmd $argv[2..-1]

    if set -q NON_INTERACTIVE; and test "$NON_INTERACTIVE" = true
        $cmd
        return $status
    end

    gum spin --spinner dot --title "$title" -- $cmd
end
