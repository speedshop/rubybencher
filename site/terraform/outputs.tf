output "pages_project_name" {
  description = "Name of the Cloudflare Pages project"
  value       = cloudflare_pages_project.rubybench.name
}

output "pages_subdomain" {
  description = "Subdomain for the Pages project"
  value       = cloudflare_pages_project.rubybench.subdomain
}

output "pages_url" {
  description = "URL of the Pages project"
  value       = "https://${cloudflare_pages_project.rubybench.subdomain}.pages.dev"
}

output "worker_route" {
  description = "Worker route pattern"
  value       = cloudflare_worker_route.rubybench.pattern
}
