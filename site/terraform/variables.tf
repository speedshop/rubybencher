variable "cloudflare_api_token" {
  description = "Cloudflare API token with Pages and Workers permissions (from CLOUDFLARE_API_TOKEN env var)"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (from CLOUDFLARE_ACCOUNT_ID env var)"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for speedshop.co (from CLOUDFLARE_ZONE_ID env var)"
  type        = string
}
