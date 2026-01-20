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
    set -l cmd $argv[2..-1]
    $cmd
    return $status
end

function log_path_for -a name
    if not set -q LOG_DIR; or test -z "$LOG_DIR"
        return 1
    end

    if test -n "$RUN_ID"
        ensure_run_log_dir
        if set -q LOG_RUN_DIR; and test -n "$LOG_RUN_DIR"
            echo "$LOG_RUN_DIR/$name.log"
            return 0
        end
    end

    set -l pending_dir "$LOG_DIR/pending"
    command mkdir -p "$pending_dir"
    set -l tag "$LOG_RUN_TAG"
    echo "$pending_dir/$name-$tag.log"
end

function log_targets_for -a log_file
    set -l targets

    if test -n "$log_file"
        set targets $targets "$log_file"
    end

    if set -q LOG_FILE; and test -n "$LOG_FILE"
        set targets $targets "$LOG_FILE"
    end

    for target in $targets
        set -l target_dir (dirname "$target")
        if test -n "$target_dir"
            command mkdir -p "$target_dir"
        end
        if not test -f "$target"
            command touch "$target"
        end
    end

    # Use printf to return each element on its own line
    # This ensures command substitution creates separate array elements
    printf '%s\n' $targets
end

function run_logged_command -a log_file
    set -l cmd $argv[2..-1]
    set -l tee_targets (log_targets_for "$log_file")

    if test (count $tee_targets) -eq 0
        $cmd
        return $status
    end

    begin; $cmd; end 2>&1 | tee -a $tee_targets
    set -l cmd_status $pipestatus[1]
    return $cmd_status
end

function run_logged_command_bg -a log_file
    set -l cmd $argv[2..-1]
    run_logged_command "$log_file" $cmd &
    set -l pid $last_pid
    echo $pid
end

function wrap_command_with_logging -a log_file
    set -l cmd $argv[2..-1]
    set -l tee_targets (log_targets_for "$log_file")
    set -l escaped_cmd (string escape -- $cmd)
    set -l cmd_string (string join " " -- $escaped_cmd)

    if test (count $tee_targets) -eq 0
        echo $cmd_string
        return 0
    end

    set -l escaped_targets
    for target in $tee_targets
        set escaped_targets $escaped_targets (string escape -- $target)
    end

    set -l targets_string (string join " " -- $escaped_targets)
    echo "begin; $cmd_string 2>&1 | tee -a $targets_string; end"
end
