# tmux utilities for running terraform in parallel panes

set -g TMUX_SESSION_NAME "rubybencher"
set -g TMUX_PANE_TEMP_DIR "/tmp/rubybencher-panes"

function ensure_tmux_session
    # If already in tmux, we're good
    if set -q TMUX
        return 0
    end

    # Create session and re-run this script inside it
    set -l script_path (status --current-filename)
    set -l run_script "$SCRIPT_DIR/run.fish"

    # Pass all original arguments
    tmux new-session -s $TMUX_SESSION_NAME "fish $run_script $argv; read -P 'Press Enter to close...'"
    exit $status
end

function tmux_init_pane_tracking
    # Create temp directory for pane exit status tracking
    mkdir -p $TMUX_PANE_TEMP_DIR
    # Clean up any stale files
    rm -f $TMUX_PANE_TEMP_DIR/*.status 2>/dev/null
    rm -f $TMUX_PANE_TEMP_DIR/*.running 2>/dev/null
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
