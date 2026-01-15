function orchestrator_file_path
    echo "$REPO_ROOT/orchestrator.json"
end

function orchestrator_exists
    test -f (orchestrator_file_path)
end

function orchestrator_get
    set -l jq_path $argv[1]

    if not orchestrator_exists
        return 1
    end

    set -l value (jq -r "$jq_path // empty" (orchestrator_file_path) 2>/dev/null)
    if test -z "$value"; or test "$value" = "null"
        return 1
    end

    echo $value
end

function orchestrator_update
    set -l filter $argv[1]
    set -l jq_args $argv[2..-1]
    set -l orchestrator_file (orchestrator_file_path)
    set -l tmp (mktemp)

    if test -f "$orchestrator_file"
        jq $jq_args "$filter" "$orchestrator_file" > "$tmp"
    else
        echo '{}' | jq $jq_args "$filter" > "$tmp"
    end

    mv "$tmp" "$orchestrator_file"
end

function orchestrator_set_meta
    set -l orchestrator_url $argv[1]
    set -l api_key $argv[2]
    set -l bastion_public_ip $argv[3]
    set -l orchestrator_public_ip $argv[4]
    set -l aws_region $argv[5]
    set -l key_name $argv[6]
    set -l s3_bucket_name $argv[7]
    set -l local_orchestrator $argv[8]
    set -l now (date -u +"%Y-%m-%dT%H:%M:%SZ")

    if test -z "$local_orchestrator"
        set local_orchestrator "false"
    end

    orchestrator_update \
        '(.created_at //= $created_at) |
         .updated_at = $updated_at |
         .orchestrator_url = $orchestrator_url |
         .api_key = $api_key |
         .bastion_public_ip = $bastion_public_ip |
         .orchestrator_public_ip = $orchestrator_public_ip |
         .aws_region = $aws_region |
         .key_name = $key_name |
         .s3_bucket_name = $s3_bucket_name |
         .local = $local' \
        --arg created_at "$now" \
        --arg updated_at "$now" \
        --arg orchestrator_url "$orchestrator_url" \
        --arg api_key "$api_key" \
        --arg bastion_public_ip "$bastion_public_ip" \
        --arg orchestrator_public_ip "$orchestrator_public_ip" \
        --arg aws_region "$aws_region" \
        --arg key_name "$key_name" \
        --arg s3_bucket_name "$s3_bucket_name" \
        --argjson local "$local_orchestrator"
end

function run_status_dir_path
    echo "$REPO_ROOT/status"
end

function ensure_run_status_dir
    set -l status_dir (run_status_dir_path)
    if not test -d "$status_dir"
        mkdir -p "$status_dir"
    end
end

function run_status_file_path
    set -l run_id $argv[1]

    if test -z "$run_id"
        set run_id "$RUN_ID"
    end

    if test -z "$run_id"
        return 1
    end

    echo "$(run_status_dir_path)/$run_id.json"
end

function run_status_exists
    set -l run_id $argv[1]
    set -l status_file (run_status_file_path "$run_id")

    if test -z "$status_file"
        return 1
    end

    test -f "$status_file"
end

function run_status_get
    set -l jq_path $argv[1]
    set -l run_id $argv[2]
    set -l status_file (run_status_file_path "$run_id")

    if test -z "$status_file"; or not test -f "$status_file"
        return 1
    end

    set -l value (jq -r "$jq_path // empty" "$status_file" 2>/dev/null)
    if test -z "$value"; or test "$value" = "null"
        return 1
    end

    echo $value
end

function run_status_update
    set -l filter $argv[1]
    set -l jq_args $argv[2..-1]
    set -l status_file (run_status_file_path)
    set -l tmp (mktemp)

    if test -z "$status_file"
        return 1
    end

    ensure_run_status_dir

    if test -f "$status_file"
        jq $jq_args "$filter" "$status_file" > "$tmp"
    else
        echo '{}' | jq $jq_args "$filter" > "$tmp"
    end

    mv "$tmp" "$status_file"
end

function config_file_hash
    if not test -f "$CONFIG_FILE"
        return 1
    end

    set -l hash ""

    if command -q shasum
        set hash (shasum -a 256 "$CONFIG_FILE" | awk '{print $1}')
    else if command -q sha256sum
        set hash (sha256sum "$CONFIG_FILE" | awk '{print $1}')
    else if command -q openssl
        set hash (openssl dgst -sha256 "$CONFIG_FILE" | awk '{print $2}')
    else
        return 1
    end

    if test -z "$hash"
        return 1
    end

    echo $hash
end

function run_status_set
    set -l run_id $argv[1]
    set -l now (date -u +"%Y-%m-%dT%H:%M:%SZ")
    set -l config_path "$CONFIG_FILE"
    set -l config_hash (config_file_hash)

    if test -z "$config_hash"
        log_warning "Unable to hash config file for run status"
        set config_hash ""
    end

    run_status_update \
        '(.created_at //= $created_at) |
         .run_id = $run_id |
         .config = { path: $config_path, sha256: $config_hash }' \
        --arg created_at "$now" \
        --arg run_id "$run_id" \
        --arg config_path "$config_path" \
        --arg config_hash "$config_hash"
end

function run_status_latest_run_id
    set -l status_dir (run_status_dir_path)
    set -l latest_run_id ""

    if not test -d "$status_dir"
        return 1
    end

    for status_file in "$status_dir"/*.json
        if not test -e "$status_file"
            continue
        end

        set -l file_name (basename "$status_file")
        set -l run_id (string replace -r '\.json$' '' "$file_name")

        if not string match -qr '^[0-9]+$' "$run_id"
            continue
        end

        if test -z "$latest_run_id"; or test "$run_id" -gt "$latest_run_id"
            set latest_run_id "$run_id"
        end
    end

    if test -n "$latest_run_id"
        echo $latest_run_id
    end
end

function resolve_resume_run_id
    set -l target $argv[1]

    if test -z "$target"
        return 1
    end

    if test "$target" = "latest"
        set -l latest_run_id (run_status_latest_run_id)
        if test -z "$latest_run_id"
            return 1
        end
        echo $latest_run_id
        return 0
    end

    echo $target
end

function enforce_run_status_config_match
    set -l run_id $argv[1]

    if not run_status_exists "$run_id"
        return 1
    end

    set -l status_path (run_status_get '.config.path' "$run_id")
    set -l status_hash (run_status_get '.config.sha256' "$run_id")

    if test -n "$status_path"; and test "$status_path" != "$CONFIG_FILE"
        log_error "Run $run_id was created with a different config file: $status_path"
        log_error "Current config: $CONFIG_FILE"
        log_error "Use the original config file when resuming a run."
        exit 1
    end

    if test -n "$status_hash"
        set -l current_hash (config_file_hash)
        if test -z "$current_hash"
            log_error "Unable to hash config file for resume check"
            exit 1
        end

        if test "$status_hash" != "$current_hash"
            log_error "Run $run_id config hash does not match current config file"
            log_error "Revert config changes or resume with the original config."
            exit 1
        end
    end

    if test -z "$status_path"; and test -z "$status_hash"
        log_warning "Run status missing config metadata; resume safety check skipped"
    end
end

function fetch_run_status
    set -l orchestrator_url $argv[1]
    set -l run_id $argv[2]

    if test -z "$orchestrator_url"; or test -z "$run_id"
        return 1
    end

    set -l tmp (mktemp)
    set -l http_code (curl -s -o "$tmp" -w "%{http_code}" "$orchestrator_url/runs/$run_id")

    if test "$http_code" != "200"
        rm -f "$tmp"
        return 1
    end

    set -l run_status (jq -r '.status // empty' "$tmp" 2>/dev/null)
    rm -f "$tmp"

    if test -z "$run_status"; or test "$run_status" = "null"
        return 1
    end

    echo $run_status
end
