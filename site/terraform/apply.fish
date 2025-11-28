#!/usr/bin/env fish
# Load .env and run terraform with Cloudflare credentials

set -l env_file (dirname (status filename))/../../.env

if not test -f $env_file
    echo "Error: .env file not found at $env_file"
    exit 1
end

# Parse .env and export as TF_VAR_* for terraform
for line in (cat $env_file | grep -v '^#' | grep '=')
    set -l key (echo $line | cut -d'=' -f1)
    set -l value (echo $line | cut -d'=' -f2-)

    switch $key
        case CLOUDFLARE_API_TOKEN
            set -gx TF_VAR_cloudflare_api_token $value
            set -gx CLOUDFLARE_API_TOKEN $value
        case CLOUDFLARE_ACCOUNT_ID
            set -gx TF_VAR_cloudflare_account_id $value
        case CLOUDFLARE_ZONE_ID
            set -gx TF_VAR_cloudflare_zone_id $value
    end
end

cd (dirname (status filename))
terraform $argv
