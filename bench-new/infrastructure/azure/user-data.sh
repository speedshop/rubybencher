#!/bin/bash
set -e

# Log everything
exec > >(tee /var/log/user-data.log) 2>&1
echo "Starting task runner setup at $(date)"

# Configuration from Terraform
ORCHESTRATOR_URL="${orchestrator_url}"
API_KEY="${api_key}"
RUN_ID="${run_id}"
PROVIDER="${provider_name}"
INSTANCE_TYPE="${instance_type}"
RUBY_VERSION="${ruby_version}"
MOCK_BENCHMARK="${mock_benchmark}"
DEBUG_MODE="${debug_mode}"
VCPU_COUNT="${vcpu_count}"

echo "Configuration:"
echo "  Orchestrator URL: $ORCHESTRATOR_URL"
echo "  Run ID: $RUN_ID"
echo "  Provider: $PROVIDER"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  Ruby Version: $RUBY_VERSION"
echo "  Mock Benchmark: $MOCK_BENCHMARK"
echo "  Debug Mode: $DEBUG_MODE"
echo "  vCPU Count: $VCPU_COUNT"

# Update system
export DEBIAN_FRONTEND=noninteractive
echo "Updating system packages..."
apt-get update -y

# Install Docker and git
echo "Installing Docker and git..."
apt-get install -y docker.io git
systemctl enable docker
systemctl start docker

# Wait for Docker to be ready
echo "Waiting for Docker to be ready..."
for i in {1..30}; do
    if docker info >/dev/null 2>&1; then
        echo "Docker is ready"
        break
    fi
    echo "Waiting for Docker... ($i/30)"
    sleep 2
done

# Clone the repository to get task-runner code
echo "Cloning repository for task-runner code..."
cd /opt
git clone --depth 1 https://github.com/speedshop/rubybencher.git repo
cd repo/bench-new/task-runner

# Build the task runner Docker image
echo "Building task runner Docker image for Ruby $RUBY_VERSION..."
docker build -t task-runner:$RUBY_VERSION --build-arg RUBY_VERSION=$RUBY_VERSION .

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to build task runner image"
    exit 1
fi

echo "Task runner image built successfully"

# Determine container arguments
CONTAINER_ARGS="--orchestrator-url $ORCHESTRATOR_URL --api-key $API_KEY --run-id $RUN_ID --provider $PROVIDER --instance-type $INSTANCE_TYPE"
CONTAINER_ENV_ARGS=""

if [ "$MOCK_BENCHMARK" = "true" ]; then
    CONTAINER_ARGS="$CONTAINER_ARGS --mock"
    CONTAINER_ENV_ARGS="$CONTAINER_ENV_ARGS -e MOCK_ALWAYS_SUCCEED=1"
fi

if [ "$DEBUG_MODE" = "true" ]; then
    CONTAINER_ARGS="$CONTAINER_ARGS --debug --no-exit"
fi

# Start task runner containers (one per vCPU, pinned to specific CPU)
echo "Starting $VCPU_COUNT task runner container(s) with CPU pinning..."

for i in $(seq 1 $VCPU_COUNT); do
    CONTAINER_NAME="task-runner-$RUN_ID-$i"
    # CPU index is 0-based, container index is 1-based
    CPU_INDEX=$((i - 1))
    echo "Starting container $i/$VCPU_COUNT: $CONTAINER_NAME (pinned to CPU $CPU_INDEX)"

    docker run -d \
        --name "$CONTAINER_NAME" \
        --cpuset-cpus="$CPU_INDEX" \
        --restart=no \
        $CONTAINER_ENV_ARGS \
        task-runner:$RUBY_VERSION \
        $CONTAINER_ARGS

    if [ $? -eq 0 ]; then
        echo "Container $CONTAINER_NAME started successfully"
    else
        echo "ERROR: Failed to start container $CONTAINER_NAME"
    fi
done

echo "Task runner setup completed at $(date)"

# Show container status
echo "Container status:"
docker ps -a --filter "name=task-runner-$RUN_ID"
