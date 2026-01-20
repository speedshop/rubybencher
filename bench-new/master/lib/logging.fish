function setup_logging
    if set -q LOG_DIR; and test -n "$LOG_DIR"
        return 0
    end

    set -g LOG_DIR "$REPO_ROOT/logs"
    command mkdir -p "$LOG_DIR"

    set -l timestamp (date -u +"%Y%m%dT%H%M%SZ")
    set -g LOG_RUN_TAG "$timestamp"
    set -g LOG_PENDING_DIR "$LOG_DIR/pending"
    command mkdir -p "$LOG_PENDING_DIR"

    set -g LOG_FILE "$LOG_PENDING_DIR/run-$LOG_RUN_TAG.log"
    command touch "$LOG_FILE"

    echo "INFO: Logging to $LOG_FILE"
end

function ensure_run_log_dir
    if not set -q RUN_ID; or test -z "$RUN_ID"
        return 0
    end

    set -l run_dir "$LOG_DIR/$RUN_ID"

    if set -q LOG_RUN_DIR; and test "$LOG_RUN_DIR" = "$run_dir"
        return 0
    end

    set -g LOG_RUN_DIR "$run_dir"
    command mkdir -p "$LOG_RUN_DIR"

    set -l target_log "$LOG_RUN_DIR/run.log"
    if set -q LOG_FILE; and test -n "$LOG_FILE"
        if test "$LOG_FILE" != "$target_log"
            if test -f "$LOG_FILE"
                command mv "$LOG_FILE" "$target_log"
            else
                command touch "$target_log"
            end
            set -g LOG_FILE "$target_log"
        end
    else
        set -g LOG_FILE "$target_log"
        command touch "$LOG_FILE"
    end
end

function log_to_file -a prefix
    if not set -q LOG_FILE; or test -z "$LOG_FILE"
        return 0
    end

    echo "$prefix: $argv[2..-1]" >> "$LOG_FILE"
end

function log_info
    log_to_file "INFO" $argv
    echo "INFO: $argv"
end

function log_success
    log_to_file "OK" $argv
    echo "OK: $argv"
end

function log_error
    log_to_file "ERROR" $argv
    echo "ERROR: $argv" 1>&2
end

function log_warning
    log_to_file "WARN" $argv
    echo "WARN: $argv"
end
