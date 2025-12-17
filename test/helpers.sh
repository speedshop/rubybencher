#!/usr/bin/env bash
# Shared test helpers

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TOTAL_TESTS=0
PASSED_TESTS=0

log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }

test_step() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo ""
    echo -e "${YELLOW}[TEST ${TOTAL_TESTS}]${NC} $1"
}

test_pass() {
    PASSED_TESTS=$((PASSED_TESTS + 1))
    log_success "PASS"
}

test_fail() {
    log_error "$1"
    exit 1
}

assert_equals() {
    local expected="$1" actual="$2" description="$3"
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $description"
    else
        test_fail "$description - expected '$expected', got '$actual'"
    fi
}

assert_not_empty() {
    local value="$1" description="$2"
    if [ -n "$value" ]; then
        echo -e "  ${GREEN}✓${NC} $description"
    else
        test_fail "$description - value is empty"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo -e "  ${GREEN}✓${NC} $description"
    else
        test_fail "$description - '$needle' not found"
    fi
}

wait_for() {
    local description="$1" max="${2:-30}" interval="${3:-2}"
    shift 3
    for i in $(seq 1 "$max"); do
        if "$@" >/dev/null 2>&1; then
            log_info "$description ready"
            return 0
        fi
        echo "Waiting for $description... ($i/$max)"
        sleep "$interval"
    done
    log_error "$description timed out"
    return 1
}

print_summary() {
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Total: ${TOTAL_TESTS} | Passed: ${PASSED_TESTS} | Failed: $((TOTAL_TESTS - PASSED_TESTS))${NC}"
    [ "$PASSED_TESTS" -eq "$TOTAL_TESTS" ] && echo -e "${GREEN}✓ All tests passed!${NC}" && return 0
    echo -e "${RED}✗ Some tests failed${NC}" && return 1
}

# API helpers - require BASE_URL and API_KEY to be set
api_get() { curl -sf "${BASE_URL}$1" 2>/dev/null || echo ""; }

api_post() {
    curl -sf -X POST \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$2" "${BASE_URL}$1" 2>/dev/null || echo ""
}

api_post_status() {
    local tmpfile=$(mktemp)
    local code=$(curl -s -o "$tmpfile" -w "%{http_code}" -X POST \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$2" "${BASE_URL}$1")
    echo "$code|$(cat "$tmpfile")"
    rm -f "$tmpfile"
}

# Docker helpers - require ORCHESTRATOR_DIR to be set
docker_exec() { docker compose -f "${ORCHESTRATOR_DIR}/docker-compose.yml" exec -T "$@"; }
rails_runner() { docker_exec web rails runner "$1"; }
