# tmux utilities for running terraform in parallel panes

set -g TMUX_SESSION_NAME "rubybencher"
set -g TMUX_PANE_TEMP_DIR "/tmp/rubybencher-panes"
set -g TMUX_MAIN_PANE_TITLE "Master"
set -g TMUX_MAIN_PANE_PERCENT 60
set -g TMUX_PANE_BORDER_STATUS "top"
set -g TMUX_PANE_BORDER_FORMAT " #{pane_title} "
set -g TMUX_PANE_SPLIT_HEIGHT "30%"

# Default layout sizing (percent of window height).
if not set -q TMUX_MAIN_PANE_PERCENT
    set -g TMUX_MAIN_PANE_PERCENT 55
end

if not set -q TMUX_BOTTOM_PANE_PERCENT
    set -g TMUX_BOTTOM_PANE_PERCENT 30
end
set -q TMUX_MAIN_PANE_HEIGHT; or set -g TMUX_MAIN_PANE_HEIGHT "40%"
set -q TMUX_PANE_SPLIT_HEIGHT; or set -g TMUX_PANE_SPLIT_HEIGHT "40%"

if not set -q TMUX_MAIN_PANE_TITLE
    set -g TMUX_MAIN_PANE_TITLE "Master"
end

if not set -q TMUX_MAIN_PANE_PERCENT
    set -g TMUX_MAIN_PANE_PERCENT 40
end

set -g TMUX_MAIN_PANE_ID ""

function tmux_sync_env
    # Copy exported env into tmux so secrets from fnox are available in panes.
    for line in (env)
        set -l parts (string split -m1 "=" -- $line)
        set -l name $parts[1]
        set -l value $parts[2]

        switch $name
            case TMUX TMUX_PANE PWD OLDPWD SHLVL FISH_PID
                continue
        end

        set -l tmux_output (tmux set-environment -g $name $value 2>&1)
        set -l tmux_status $status
        if test $tmux_status -ne 0
            if test -z "$tmux_output"
                set tmux_output "unknown tmux error"
            end
            log_error "tmux set-environment failed for $name: $tmux_output"
            if test "$DEBUG" = true
                tmux_debug_context
            end
            return $tmux_status
        end
    end
end

function tmux_debug_context
    if not set -q TMUX
        return 0
    end

    set -l session_name (tmux display-message -p "#S" 2>/dev/null)
    set -l window_name (tmux display-message -p "#W" 2>/dev/null)
    set -l pane_id (tmux display-message -p "#P" 2>/dev/null)
    set -l window_size (tmux display-message -p "#{window_width}x#{window_height}" 2>/dev/null)

    if test -n "$session_name"
        log_info "tmux session: $session_name window: $window_name pane: $pane_id size: $window_size"
    end

    if test "$DEBUG" = true
        set -l panes (tmux list-panes -F '#{pane_id}:#{pane_title}' 2>/dev/null)
        if test -n "$panes"
            set -l panes_line (string join ", " -- $panes)
            log_info "tmux panes: $panes_line"
        end
    end
end

function ensure_tmux_session
    # If already in tmux, we're good
    if set -q TMUX
        tmux_sync_env
        if test "$DEBUG" = true
            tmux_debug_context
        end
        return 0
    end

    # Skip tmux in non-interactive mode (for CI)
    if contains -- --non-interactive $argv
        return 0
    end

    # Create session and re-run this script inside it
    set -l script_path (status --current-filename)
    set -l run_script "$SCRIPT_DIR/run.fish"

    # Pass all original arguments
    tmux new-session -s $TMUX_SESSION_NAME "fish $run_script $argv; read -P 'Press Enter to close...'"
    exit $status
end

function tmux_configure_window
    if not set -q TMUX
        return 0
    end

    set -l main_title "Master"
    if set -q TMUX_MAIN_PANE_TITLE
        set main_title "$TMUX_MAIN_PANE_TITLE"
    end

    tmux rename-window "master"
    tmux select-pane -t "$TMUX_PANE" -T "$main_title"

    tmux set-window-option -t "$TMUX_PANE" pane-border-status top
    tmux set-window-option -t "$TMUX_PANE" pane-border-format ' #{pane_title} '

    # Allow tuning main pane height via TMUX_MAIN_PANE_HEIGHT_PCT.
    set -l height_pct 45
    if set -q TMUX_MAIN_PANE_HEIGHT_PCT
        set height_pct $TMUX_MAIN_PANE_HEIGHT_PCT
    end

    if not string match -qr '^[0-9]+$' -- $height_pct
        set height_pct 45
    end

    if test $height_pct -lt 20
        set height_pct 20
    else if test $height_pct -gt 80
        set height_pct 80
    end

    set -l window_height (tmux display-message -p "#{window_height}")
    if string match -qr '^[0-9]+$' -- $window_height
        set -l main_height (math "floor($window_height * $height_pct / 100)")
        if test $main_height -lt 6
            set main_height 6
        end
        tmux set-window-option -t "$TMUX_PANE" main-pane-height $main_height
    end
end

function tmux_init_pane_tracking
    # Create temp directory for pane exit status tracking
    mkdir -p $TMUX_PANE_TEMP_DIR
    # Clean up any stale files
    command find $TMUX_PANE_TEMP_DIR -type f -name "*.status" -delete 2>/dev/null
    command find $TMUX_PANE_TEMP_DIR -type f -name "*.running" -delete 2>/dev/null
end

function tmux_spawn_pane -a title
    # Spawn a new pane below, run the command, capture exit status
    # Returns the pane ID which can be used to wait for completion
    #
    # Args:
    #   title - displayed in pane (via printf at start)
    #   - remaining arguments: the command and its arguments

    set -l cmd $argv[2..-1]

    if not set -q TMUX
        log_error "tmux_spawn_pane called outside tmux"
        return 1
    end

    set -l panes_before ""
    if test "$DEBUG" = true
        log_info "Preparing tmux pane: $title"
        tmux_debug_context
        log_info "tmux pane command: $cmd"
        set panes_before (tmux list-panes -F '#{pane_id}:#{pane_title}' 2>/dev/null)
    end

    set -l pane_id (random)
    set -l status_file "$TMUX_PANE_TEMP_DIR/$pane_id.status"
    set -l running_file "$TMUX_PANE_TEMP_DIR/$pane_id.running"

    mkdir -p $TMUX_PANE_TEMP_DIR
    command touch $running_file

    set -l escaped_status_file (string escape -- $status_file)
    set -l escaped_running_file (string escape -- $running_file)
    set -l escaped_title (string escape -- $title)

    # Build the command that will run in the pane
    # It prints a title, runs the command, saves exit status, removes running marker
    set -l pane_cmd "fish -c \"
        printf \\\\x1b'['1';'36'm━━━ $escaped_title ━━━\\\\x1b'['0'm'\\n''\\n'
        $cmd
        set exit_code \\\$status
        echo \\\$exit_code > $escaped_status_file
        rm -f $escaped_running_file
        if test \\\$exit_code -ne 0
            printf \\\\x1b'['1';'31'm━━━ FAILED (exit \\\$exit_code) ━━━\\\\x1b'['0'm'\\n'
            sleep 5
        end
    \""

    # Split window horizontally (new pane below)
    set -l split_output (tmux split-window -v -d -l 30% "$pane_cmd" 2>&1)
    set -l split_status $status
    if test $split_status -ne 0
        command rm -f $running_file
        if test -z "$split_output"
            set split_output "unknown tmux error"
        end
        log_error "Failed to spawn tmux pane: $split_output"
        tmux_debug_context
        echo $pane_id
        return $split_status
    end

    if test "$DEBUG" = true
        log_info "Spawned tmux pane for $title"
    end

    # Rebalance layout to tile bottom panes
    set -l layout_output (tmux select-layout main-horizontal 2>&1)
    set -l layout_status $status
    if test $layout_status -ne 0
        if test -z "$layout_output"
            set layout_output "unknown tmux error"
        end
        log_warning "tmux select-layout failed: $layout_output"
        tmux_debug_context
    end

    if test "$DEBUG" = true
        set -l panes_after (tmux list-panes -F '#{pane_id}:#{pane_title}' 2>/dev/null)
        if test -n "$panes_before"
            log_info "tmux panes before: $panes_before"
        end
        if test -n "$panes_after"
            log_info "tmux panes after: $panes_after"
        end
    end

    echo $pane_id
end

function tmux_wait_pane -a pane_id
    # Wait for a pane to complete and return its exit status
    set -l status_file "$TMUX_PANE_TEMP_DIR/$pane_id.status"
    set -l running_file "$TMUX_PANE_TEMP_DIR/$pane_id.running"

    # Poll until the running file is gone
    while test -f $running_file
        sleep 0.5
    end

    # Read exit status
    if test -f $status_file
        set -l exit_status (cat $status_file)
        rm -f $status_file
        return $exit_status
    end

    # If no status file, assume failure
    return 1
end

function tmux_wait_all_panes
    # Wait for all tracked panes to complete
    # Args: list of pane IDs
    # Returns: 0 if all succeeded, 1 if any failed
    set -l pane_ids $argv
    set -l any_failed 0

    for pane_id in $pane_ids
        tmux_wait_pane $pane_id
        if test $status -ne 0
            set any_failed 1
        end
    end

    return $any_failed
end

function tmux_cleanup
    # Clean up temp files
    rm -rf $TMUX_PANE_TEMP_DIR 2>/dev/null
end
