#!/bin/sh
set -e

# Remove stale server PID file
rm -f tmp/pids/server.pid

# Prepare primary database (create if needed, run migrations)
bin/rails db:prepare

# Load SolidQueue schema if tables don't exist
# We check by trying to query the table - if it fails, load the schema
if ! bin/rails runner "SolidQueue::Job.first" 2>/dev/null; then
  echo "Loading SolidQueue schema..."
  DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bin/rails db:schema:load:queue
fi

# Execute the main command
exec "$@"
