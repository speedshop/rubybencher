terraform {
  required_version = ">= 1.9.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Cloudflare Pages project for hosting the benchmark report
resource "cloudflare_pages_project" "rubybench" {
  account_id        = var.cloudflare_account_id
  name              = "rubybench"
  production_branch = "main"

  build_config {
    build_command   = ""
    destination_dir = "public"
  }

  deployment_configs {
    production {
      compatibility_date = "2024-01-01"
    }
    preview {
      compatibility_date = "2024-01-01"
    }
  }
}

# Cloudflare Worker to proxy /rubybench to Pages
resource "cloudflare_worker_script" "rubybench_proxy" {
  account_id = var.cloudflare_account_id
  name       = "rubybench-proxy"
  content    = file("${path.module}/../worker.js")
  module     = true
}

# Worker route to handle /rubybench/* on speedshop.co
resource "cloudflare_worker_route" "rubybench" {
  zone_id     = var.cloudflare_zone_id
  pattern     = "speedshop.co/rubybench*"
  script_name = cloudflare_worker_script.rubybench_proxy.name
}

resource "cloudflare_worker_route" "rubybench_www" {
  zone_id     = var.cloudflare_zone_id
  pattern     = "www.speedshop.co/rubybench*"
  script_name = cloudflare_worker_script.rubybench_proxy.name
}
