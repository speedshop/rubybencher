# ECR functions for building and pushing task runner images

function ecr_login
    # Authenticate with ECR using AWS credentials
    set -l meta_tf_dir "$BENCH_DIR/infrastructure/meta"
    set -l aws_region (terraform -chdir="$meta_tf_dir" output -raw aws_region 2>/dev/null || echo "us-east-1")
    set -l ecr_url (terraform -chdir="$meta_tf_dir" output -raw ecr_repository_url 2>/dev/null)

    if test -z "$ecr_url"
        log_error "ECR repository URL not found in meta terraform outputs"
        return 1
    end

    # Extract registry URL (everything before the first /)
    set -l registry (string replace -r '/.*' '' $ecr_url)

    log_info "Logging in to ECR: $registry"
    aws ecr get-login-password --region $aws_region | docker login --username AWS --password-stdin $registry
    if test $status -ne 0
        log_error "Failed to login to ECR"
        return 1
    end

    return 0
end

function ecr_image_exists
    # Check if image with given tag exists in ECR
    # Returns 0 if exists, 1 if not
    set -l image_tag $argv[1]
    set -l meta_tf_dir "$BENCH_DIR/infrastructure/meta"
    set -l aws_region (terraform -chdir="$meta_tf_dir" output -raw aws_region 2>/dev/null || echo "us-east-1")
    set -l ecr_repo_name (terraform -chdir="$meta_tf_dir" output -raw ecr_repository_name 2>/dev/null)

    if test -z "$ecr_repo_name"
        return 1
    end

    aws ecr describe-images \
        --repository-name "$ecr_repo_name" \
        --image-ids imageTag="$image_tag" \
        --region "$aws_region" >/dev/null 2>&1

    return $status
end

function get_task_runner_image_tag
    # Generate image tag based on ruby version and git hash
    # Format: ruby{VERSION}-{GIT_HASH}
    set -l ruby_version (cat "$CONFIG_FILE" | jq -r '.ruby_version')
    set -l git_hash (git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

    echo "ruby$ruby_version-$git_hash"
end

function get_task_runner_image
    # Return the full ECR image URL with tag
    set -l meta_tf_dir "$BENCH_DIR/infrastructure/meta"
    set -l ecr_url (terraform -chdir="$meta_tf_dir" output -raw ecr_repository_url 2>/dev/null)
    set -l image_tag (get_task_runner_image_tag)

    echo "$ecr_url:$image_tag"
end

function build_and_push_task_runner_image
    # Build multi-arch task runner image and push to ECR
    # Skips build if image already exists with same tag

    set -l meta_tf_dir "$BENCH_DIR/infrastructure/meta"
    set -l ecr_url (terraform -chdir="$meta_tf_dir" output -raw ecr_repository_url 2>/dev/null)

    if test -z "$ecr_url"
        log_error "ECR repository URL not found - ensure meta terraform has been applied"
        return 1
    end

    set -l image_tag (get_task_runner_image_tag)
    set -l full_image "$ecr_url:$image_tag"
    set -l ruby_version (cat "$CONFIG_FILE" | jq -r '.ruby_version')

    log_info "Task runner image tag: $image_tag"

    # Check if image already exists
    if ecr_image_exists "$image_tag"
        log_success "Task runner image already exists in ECR: $full_image"
        set -g TASK_RUNNER_IMAGE "$full_image"
        return 0
    end

    log_info "Building and pushing task runner image to ECR..."

    # Login to ECR
    if not ecr_login
        return 1
    end

    # Build multi-arch image with buildx
    set -l task_runner_dir "$BENCH_DIR/task-runner"

    if not test -d "$task_runner_dir"
        log_error "Task runner directory not found: $task_runner_dir"
        return 1
    end

    # Ensure buildx builder exists
    if not docker buildx inspect rubybencher-builder >/dev/null 2>&1
        log_info "Creating buildx builder for multi-arch builds..."
        docker buildx create --name rubybencher-builder --use
    else
        docker buildx use rubybencher-builder
    end

    log_info "Building multi-arch image (arm64 + amd64)..."
    docker buildx build \
        --platform linux/arm64,linux/amd64 \
        --build-arg RUBY_VERSION="$ruby_version" \
        --tag "$full_image" \
        --push \
        "$task_runner_dir"

    if test $status -ne 0
        log_error "Failed to build and push task runner image"
        return 1
    end

    log_success "Task runner image pushed to ECR: $full_image"
    set -g TASK_RUNNER_IMAGE "$full_image"
    return 0
end
