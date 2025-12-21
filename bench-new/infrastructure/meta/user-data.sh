#!/bin/bash
set -e

# Log everything
exec > >(tee /var/log/user-data.log) 2>&1
echo "Starting user-data script at $(date)"

# Update system
dnf update -y

# Install Docker and git
dnf install -y docker git
systemctl enable docker
systemctl start docker

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Add ec2-user to docker group
usermod -aG docker ec2-user

# Create app directory
mkdir -p /opt/orchestrator
cd /opt/orchestrator

# Create environment file with secrets
cat > /opt/orchestrator/.env << 'ENVEOF'
RAILS_ENV=production
RAILS_MASTER_KEY=${rails_master_key}
POSTGRES_PASSWORD=${postgres_password}
AWS_REGION=${aws_region}
AWS_ACCESS_KEY_ID=${aws_access_key_id}
AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
S3_BUCKET_NAME=${s3_bucket}
API_KEY=${api_key}
ENVEOF

# Create docker-compose file
cat > /opt/orchestrator/docker-compose.yml << 'COMPOSEEOF'
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: orchestrator
      POSTGRES_PASSWORD: $${POSTGRES_PASSWORD}
      POSTGRES_DB: orchestrator_production
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U orchestrator"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  orchestrator:
    image: orchestrator:latest
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      RAILS_ENV: production
      RAILS_MASTER_KEY: $${RAILS_MASTER_KEY}
      DATABASE_URL: postgres://orchestrator:$${POSTGRES_PASSWORD}@postgres:5432/orchestrator_production
      AWS_REGION: $${AWS_REGION:-us-east-1}
      AWS_ACCESS_KEY_ID: $${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: $${AWS_SECRET_ACCESS_KEY}
      S3_BUCKET_NAME: $${S3_BUCKET_NAME}
      API_KEY: $${API_KEY}
      RAILS_SERVE_STATIC_FILES: "true"
      RAILS_LOG_TO_STDOUT: "true"
    ports:
      - "80:3000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/up"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    restart: unless-stopped

  worker:
    image: orchestrator:latest
    command: bin/jobs
    depends_on:
      postgres:
        condition: service_healthy
      orchestrator:
        condition: service_healthy
    environment:
      RAILS_ENV: production
      RAILS_MASTER_KEY: $${RAILS_MASTER_KEY}
      DATABASE_URL: postgres://orchestrator:$${POSTGRES_PASSWORD}@postgres:5432/orchestrator_production
      AWS_REGION: $${AWS_REGION:-us-east-1}
      AWS_ACCESS_KEY_ID: $${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: $${AWS_SECRET_ACCESS_KEY}
      S3_BUCKET_NAME: $${S3_BUCKET_NAME}
      API_KEY: $${API_KEY}
      RAILS_LOG_TO_STDOUT: "true"
    restart: unless-stopped

volumes:
  postgres_data:
COMPOSEEOF

# Create deploy script
cat > /opt/orchestrator/deploy.sh << 'DEPLOYEOF'
#!/bin/bash
set -e
cd /opt/orchestrator

# Clone or update repo
if [ -d "orchestrator" ]; then
  cd orchestrator
  git pull
  cd ..
else
  git clone --depth 1 https://github.com/speedshop/rubybencher.git repo
  cp -r repo/bench-new/orchestrator .
  rm -rf repo
fi

# Build and deploy
docker-compose build
docker-compose up -d
DEPLOYEOF
chmod +x /opt/orchestrator/deploy.sh

echo "User-data script completed at $(date)"
echo "To deploy, SSH in and run: cd /opt/orchestrator && ./deploy.sh"
echo "Or manually: scp the orchestrator folder, then docker-compose build && docker-compose up -d"
