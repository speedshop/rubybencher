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

        tmux set-environment -g $name $value
    end
end

function ensure_tmux_session
    # If already in tmux, we're good
    if set -q TMUX
        return 0
    end

    # Create session and re-run this script inside it
    set -l script_path (status --current-filename)
    set -l run_script "$SCRIPT_DIR/run.fish"

    # Pass all original arguments
    tmux_sync_env
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

function tmux_spawn_pane -a title cmd
    # Spawn a new pane below, run the command, capture exit status
    # Returns the pane ID which can be used to wait for completion
    #
    # Args:
    #   title - displayed in pane (via printf at start)
    #   cmd   - command to run

    set -l pane_id (random)
    set -l status_file "$TMUX_PANE_TEMP_DIR/$pane_id.status"
    set -l running_file "$TMUX_PANE_TEMP_DIR/$pane_id.running"

    # Create running marker
    touch $running_file

    # Build the command that will run in the pane
    # It prints a title, runs the command, saves exit status, removes running marker
    set -l pane_cmd "fish -c '
        printf \"\\033[1;36m━━━ $title ━━━\\033[0m\\n\\n\"
        $cmd
        set -l exit_code \$status
        echo \$exit_code > $status_file
        rm -f $running_file
        if test \$exit_code -ne 0
            printf \"\\n\\033[1;31m━━━ FAILED (exit \$exit_code) ━━━\\033[0m\\n\"
            sleep 5
        end
    '"

    # Split window horizontally (new pane below)
    tmux split-window -v -d -l 30% "$pane_cmd"

    # Rebalance layout to tile bottom panes
    tmux select-layout main-horizontal

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
