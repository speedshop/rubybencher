#!/usr/bin/env fish
# Run terraform with Cloudflare credentials from environment

# Map CLOUDFLARE_* env vars to TF_VAR_* for terraform
set -gx TF_VAR_cloudflare_api_token $CLOUDFLARE_API_TOKEN
set -gx TF_VAR_cloudflare_account_id $CLOUDFLARE_ACCOUNT_ID
set -gx TF_VAR_cloudflare_zone_id $CLOUDFLARE_ZONE_ID

cd (dirname (status filename))
terraform $argv
