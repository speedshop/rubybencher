#!/usr/bin/env bash
# Setup orchestrator services for testing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCHESTRATOR_DIR="$REPO_ROOT/bench-new/orchestrator"
source "$REPO_ROOT/test/helpers.sh"

cd "$ORCHESTRATOR_DIR"

# Use development environment (docker-compose creates orchestrator_development DB)
export RAILS_ENV=development

log_info "Starting Docker services..."
docker compose up -d

log_info "Waiting for PostgreSQL..."
wait_for "PostgreSQL" 30 2 docker compose exec -T postgres pg_isready -U orchestrator

log_info "Waiting for MinIO..."
wait_for "MinIO" 30 2 curl -sf http://localhost:9000/minio/health/live

log_info "Running migrations..."
docker compose exec -T web rails db:migrate 2>/dev/null || true

log_info "Loading Solid Queue schema..."
docker compose exec -T web rails db:schema:load:queue 2>/dev/null || true

log_info "Waiting for web service..."
wait_for "Web" 30 2 curl -sf http://localhost:3000/up

log_info "Waiting for worker to start..."
sleep 5

log_success "All services ready"
