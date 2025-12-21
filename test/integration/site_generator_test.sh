#!/usr/bin/env bash
# Integration test: Site Generator
# Tests that the report generator creates valid HTML output from benchmark results
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SITE_DIR="$REPO_ROOT/site"
RESULTS_DIR="$REPO_ROOT/results"

# Source test helpers
source "$REPO_ROOT/test/helpers.sh"

echo -e "\n${YELLOW}═══ Site Generator Integration Test ═══${NC}\n"

# Setup test data
test_step "Create sample benchmark results"

TEST_RUN_ID="site-gen-test-$(date +%s)"
TEST_RESULTS_DIR="$RESULTS_DIR/$TEST_RUN_ID"

mkdir -p "$TEST_RESULTS_DIR/local-docker-1"
mkdir -p "$TEST_RESULTS_DIR/local-docker-2"
mkdir -p "$SITE_DIR/static/css" "$SITE_DIR/static/js"

# Create first instance results
cat > "$TEST_RESULTS_DIR/local-docker-1/output.json" << 'EOF'
{
  "raw_data": {
    "=yjit": {
      "app_aobench": {
        "RUBY_DESCRIPTION": "ruby 3.4.1 (2024-12-25 revision abcd1234) +YJIT +PRISM [x86_64-linux]",
        "bench": [1.5, 1.2, 1.1, 1.0, 1.05]
      },
      "liquid-render": {
        "RUBY_DESCRIPTION": "ruby 3.4.1 (2024-12-25 revision abcd1234) +YJIT +PRISM [x86_64-linux]",
        "bench": [0.5, 0.45, 0.48, 0.52, 0.47]
      }
    }
  }
}
EOF

cat > "$TEST_RESULTS_DIR/local-docker-1/metadata.json" << 'EOF'
{"provider":"local","instance_type":"docker","ruby_version":"3.4.1"}
EOF

# Create second instance results (for comparison)
cat > "$TEST_RESULTS_DIR/local-docker-2/output.json" << 'EOF'
{
  "raw_data": {
    "=yjit": {
      "app_aobench": {
        "RUBY_DESCRIPTION": "ruby 3.4.1 (2024-12-25 revision abcd1234) +YJIT +PRISM [x86_64-linux]",
        "bench": [1.3, 1.25, 1.15, 1.1, 1.08]
      },
      "liquid-render": {
        "RUBY_DESCRIPTION": "ruby 3.4.1 (2024-12-25 revision abcd1234) +YJIT +PRISM [x86_64-linux]",
        "bench": [0.55, 0.5, 0.52, 0.54, 0.51]
      }
    }
  }
}
EOF

cat > "$TEST_RESULTS_DIR/local-docker-2/metadata.json" << 'EOF'
{"provider":"aws","instance_type":"c6g.medium","ruby_version":"3.4.1"}
EOF

test_pass

# Run generator
test_step "Generate HTML report"

cd "$SITE_DIR"
OUTPUT=$(ruby generate_report.rb "$TEST_RUN_ID" 2>&1) || {
    echo "$OUTPUT"
    test_fail "Report generation failed"
}

log_info "$OUTPUT"
test_pass

# Verify output files exist
test_step "Verify output files created"

[ -f "$SITE_DIR/public/index.html" ] || test_fail "index.html not created"
[ -f "$SITE_DIR/public/data.json" ] || test_fail "data.json not created"

log_info "index.html size: $(wc -c < "$SITE_DIR/public/index.html") bytes"
log_info "data.json size: $(wc -c < "$SITE_DIR/public/data.json") bytes"
test_pass

# Verify content
test_step "Verify report contains benchmark data"

grep -q "app_aobench" "$SITE_DIR/public/index.html" || test_fail "Benchmark 'app_aobench' not found in report"
grep -q "liquid-render" "$SITE_DIR/public/index.html" || test_fail "Benchmark 'liquid-render' not found in report"
grep -q "local-docker" "$SITE_DIR/public/index.html" || test_fail "Instance 'local-docker' not found in report"

test_pass

# Verify JSON data structure
test_step "Verify data.json is valid JSON"

jq -e . "$SITE_DIR/public/data.json" > /dev/null || test_fail "data.json is not valid JSON"

DATA_ENTRIES=$(jq 'length' "$SITE_DIR/public/data.json")
[ "$DATA_ENTRIES" -gt 0 ] || test_fail "data.json has no entries"

log_info "data.json contains $DATA_ENTRIES data points"
test_pass

# Cleanup
test_step "Cleanup test data"

rm -rf "$TEST_RESULTS_DIR"
rm -f "$SITE_DIR/public/index.html" "$SITE_DIR/public/data.json"

test_pass

print_summary
