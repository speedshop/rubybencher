#!/bin/bash
set -euo pipefail

RUN_ID="${run_id}"
INSTANCE_KEY="${instance_key}"
RESULT_URL="${result_url}"
ERROR_URL="${error_url}"
HEARTBEAT_URL="${heartbeat_url}"
PROVIDER="aws"
TYPE_NAME="${instance_type}"
HEARTBEAT_INTERVAL=30
HEARTBEAT_STAGE_FILE="/tmp/heartbeat_stage"

shutdown -h +90 &

dnf install -y docker git at tar gzip curl jq
systemctl enable docker atd
systemctl start docker atd
usermod -aG docker ec2-user

heartbeat_stage() {
  cat "$HEARTBEAT_STAGE_FILE" 2>/dev/null || echo "unknown"
}

write_stage() {
  echo "$1" >"$HEARTBEAT_STAGE_FILE"
}

send_heartbeat() {
  [[ -z "$HEARTBEAT_URL" ]] && return
  local stage ts payload
  stage="$(heartbeat_stage)"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  payload=$(printf '{"timestamp":"%s","stage":"%s"}' "$ts" "$stage")
  curl -sS -m 5 -X PUT -H "Content-Type: application/json" -d "$payload" "$HEARTBEAT_URL" >/dev/null 2>&1 || true
}

start_heartbeat_loop() {
  [[ -z "$HEARTBEAT_URL" ]] && return
  write_stage "boot"
  send_heartbeat
  while true; do
    send_heartbeat
    sleep "$HEARTBEAT_INTERVAL"
  done &
}

cat >/home/ec2-user/run_bench.sh <<'SCRIPT'
#!/bin/bash
set -uo pipefail
RESULT_DIR=/tmp/results
LOG_FILE=/tmp/bench.log
RUN_ID="${run_id}"
INSTANCE_KEY="${instance_key}"
PROVIDER="aws"
TYPE_NAME="${instance_type}"
RESULT_URL="${result_url}"
ERROR_URL="${error_url}"
HEARTBEAT_URL="${heartbeat_url}"
HEARTBEAT_INTERVAL=30
HEARTBEAT_STAGE_FILE="/tmp/heartbeat_stage"

heartbeat_stage() {
  cat "$HEARTBEAT_STAGE_FILE" 2>/dev/null || echo "unknown"
}

write_stage() {
  echo "$1" >"$HEARTBEAT_STAGE_FILE"
}

send_heartbeat() {
  [[ -z "$HEARTBEAT_URL" ]] && return
  local stage ts payload
  stage="$(heartbeat_stage)"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  payload=$(printf '{"timestamp":"%s","stage":"%s"}' "$ts" "$stage")
  curl -sS -m 5 -X PUT -H "Content-Type: application/json" -d "$payload" "$HEARTBEAT_URL" >/dev/null 2>&1 || true
}

start_heartbeat_loop() {
  [[ -z "$HEARTBEAT_URL" ]] && return
  write_stage "boot"
  send_heartbeat
  while true; do
    send_heartbeat
    sleep "$HEARTBEAT_INTERVAL"
  done &
}

mkdir -p "$RESULT_DIR"

run_bench() {
  docker run --rm \
    -e RUBY_YJIT_ENABLE=1 \
    -v "$RESULT_DIR":/results \
    ruby:3.4 \
    bash -c "apt-get update && apt-get install -y nodejs npm git > /dev/null 2>&1 && git clone https://github.com/ruby/ruby-bench /ruby-bench && cd /ruby-bench && ./run_benchmarks.rb 2>&1 | tee /results/output.txt && cp -r *.csv *.json /results/ 2>/dev/null || true"
}

start_heartbeat_loop
write_stage "running"
run_bench >>"$LOG_FILE" 2>&1
status=$?
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [ $status -eq 0 ] && grep -q "Average of last" "$RESULT_DIR/output.txt"; then
  cat >"$RESULT_DIR/meta.json" <<META
{"run_id":"$RUN_ID","instance_key":"$INSTANCE_KEY","provider":"$PROVIDER","instance_type":"$TYPE_NAME","status":"success","finished_at":"$timestamp"}
META
  tar czf /tmp/result.tar.gz -C "$RESULT_DIR" .
  if [ -n "$RESULT_URL" ]; then
    curl -sSf -X PUT -T /tmp/result.tar.gz "$RESULT_URL"
  fi
  write_stage "finished"
  send_heartbeat
else
  tail -n 400 "$LOG_FILE" > /tmp/error.log || true
  cat >/tmp/error_meta.json <<META
{"run_id":"$RUN_ID","instance_key":"$INSTANCE_KEY","provider":"$PROVIDER","instance_type":"$TYPE_NAME","status":"error","finished_at":"$timestamp"}
META
  tar czf /tmp/error.tar.gz /tmp/error.log /tmp/error_meta.json 2>/dev/null || true
  if [ -n "$ERROR_URL" ]; then
    curl -sSf -X PUT -T /tmp/error.tar.gz "$ERROR_URL" || true
  fi
  write_stage "error"
  send_heartbeat
fi
exit 0
SCRIPT

chmod +x /home/ec2-user/run_bench.sh
su - ec2-user -c "/home/ec2-user/run_bench.sh" || true
shutdown -h +5 &
