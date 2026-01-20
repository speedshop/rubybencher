ARG RUBY_VERSION=3.4

FROM ruby:${RUBY_VERSION}

# Install git for cloning ruby-bench, nodejs for shipit, libclang for commonmarker, and sudo for ruby-bench CPU config
RUN apt-get update && apt-get install -y git nodejs npm libclang-dev clang sudo && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /task-runner

# Copy Gemfile first for layer caching
COPY Gemfile /task-runner/
RUN bundle install

# Copy scripts and Ruby code
COPY run.sh /task-runner/
COPY lib/ /task-runner/lib/
COPY mock/ /task-runner/mock/

# Make scripts executable
RUN chmod +x /task-runner/run.sh \
    && chmod +x /task-runner/mock/benchmark.sh

# Set entrypoint
ENTRYPOINT ["/task-runner/run.sh"]
