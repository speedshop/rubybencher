# Dockerfile for orchestrator
# Used by docker-compose.yml for local development and CI

ARG RUBY_VERSION=3.4.7
ARG PRECOMPILE_ASSETS=false
FROM docker.io/library/ruby:$RUBY_VERSION-slim

# Install dependencies
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    build-essential \
    curl \
    git \
    libpq-dev \
    libyaml-dev \
    pkg-config \
    postgresql-client \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /rails

# Install gems
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copy application code
COPY . .

# Precompile assets for production (pass --build-arg PRECOMPILE_ASSETS=true)
ARG PRECOMPILE_ASSETS=false
RUN if [ "$PRECOMPILE_ASSETS" = "true" ]; then \
      SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile; \
    fi

# Prepare database and start server
EXPOSE 3000
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
