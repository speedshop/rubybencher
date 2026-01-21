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
TASK_RUNNER_IMAGE="${task_runner_image}"
AWS_REGION="${aws_region}"
MOCK_BENCHMARK="${mock_benchmark}"
DEBUG_MODE="${debug_mode}"
VCPU_COUNT="${vcpu_count}"

echo "Configuration:"
echo "  Orchestrator URL: $ORCHESTRATOR_URL"
echo "  Run ID: $RUN_ID"
echo "  Provider: $PROVIDER"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  Ruby Version: $RUBY_VERSION"
echo "  Task Runner Image: $TASK_RUNNER_IMAGE"
echo "  AWS Region: $AWS_REGION"
echo "  Mock Benchmark: $MOCK_BENCHMARK"
echo "  Debug Mode: $DEBUG_MODE"
echo "  vCPU Count: $VCPU_COUNT"

# Update system
echo "Updating system packages..."
dnf update -y

# Install Docker
echo "Installing Docker..."
dnf install -y docker
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

# Login to ECR using instance role (no credentials needed)
echo "Logging in to ECR..."
# Extract registry URL from image (everything before the first /)
ECR_REGISTRY=$(echo "$TASK_RUNNER_IMAGE" | cut -d'/' -f1)

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to login to ECR"
    exit 1
fi

echo "ECR login successful"

# Pull the prebuilt task runner image
echo "Pulling task runner image from ECR: $TASK_RUNNER_IMAGE"
docker pull "$TASK_RUNNER_IMAGE"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to pull task runner image"
    exit 1
fi

echo "Task runner image pulled successfully"

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
        "$TASK_RUNNER_IMAGE" \
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
