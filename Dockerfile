FROM ubuntu:24.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies and tools (including nginx)
RUN apt-get update && apt-get install -y \
    software-properties-common \
    curl \
    wget \
    git \
    build-essential \
    ca-certificates \
    unzip \
    zip \
    jq \
    htop \
    tmux \
    openssh-client \
    rclone \
    magic-wormhole \
    nginx \
    && rm -rf /var/lib/apt/lists/*

# Add deadsnakes PPA for Python 3.13
RUN add-apt-repository -y ppa:deadsnakes/ppa && \
    apt-get update && apt-get install -y \
    python3.13 \
    python3.13-venv \
    python3.13-dev \
    && apt-get install -y python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Set Python 3.13 as default and create alias
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.13 1 && \
    ln -sf /usr/bin/python3.13 /usr/bin/python

# Create opencode user and workspace
RUN useradd -m -s /bin/bash opencode && \
    mkdir -p /home/opencode/workspace && \
    chown -R opencode:opencode /home/opencode && \
    apt-get update && apt-get install -y sudo && \
    echo "opencode ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/opencode && \
    chmod 0440 /etc/sudoers.d/opencode && \
    rm -rf /var/lib/apt/lists/*

# Copy opencode config to workspace
COPY opencode.json /home/opencode/workspace/
RUN chown opencode:opencode /home/opencode/workspace/opencode.json

# Set working directory
WORKDIR /home/opencode/workspace

# Install Node.js (LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="${PATH}:/root/.bun/bin"

# Install uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="${PATH}:/root/.cargo/bin"

# Install Go (multi-arch)
RUN if [ "$(uname -m)" = "aarch64" ]; then \
      GOARCH=arm64; \
    elif [ "$(uname -m)" = "x86_64" ]; then \
      GOARCH=amd64; \
    else \
      GOARCH=$(uname -m); \
    fi && \
    wget https://go.dev/dl/go1.23.5.linux-${GOARCH}.tar.gz && \
    rm -rf /usr/local/go && tar -C /usr/local -xzf go1.23.5.linux-${GOARCH}.tar.gz && \
    rm go1.23.5.linux-${GOARCH}.tar.gz
ENV PATH="${PATH}:/usr/local/go/bin"

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="${PATH}:/root/.cargo/bin"

# Install OpenCode CLI
RUN curl -fsSL https://opencode.ai/install | bash && \
    export PATH="${PATH}:$(find /root -name opencode -type f -executable 2>/dev/null | xargs dirname | head -1)" || true
ENV PATH="${PATH}:/root/.local/bin:/root/.opencode/bin"

# Verify installations
RUN echo "=== Python ===" && python3 --version && \
    echo "=== Node.js ===" && node --version && \
    echo "=== npm ===" && npm --version && \
    echo "=== Bun ===" && bun --version && \
    echo "=== uv ===" && uv --version && \
    echo "=== Go ===" && go version && \
    echo "=== Rust ===" && rustc --version && \
    echo "=== Cargo ===" && cargo --version && \
    echo "=== OpenCode ===" && opencode --version && \
    echo "=== Rclone ===" && rclone version

# Configure nginx as a CSP-fixing reverse proxy for opencode
RUN rm -f /etc/nginx/sites-enabled/default && \
    cat > /etc/nginx/conf.d/opencode.conf << 'NGINXCONF'
server {
    listen 8080;

    location / {
        proxy_pass http://127.0.0.1:4096;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;

        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "script-src 'self' 'wasm-unsafe-eval'; default-src 'self'; connect-src 'self' wss: ws:; img-src 'self' data:; style-src 'self' 'unsafe-inline';" always;
    }
}
NGINXCONF

# Create entrypoint script
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

# Start opencode web server in background (bound to localhost only)
opencode web --port 4096 --hostname 127.0.0.1 &

# Wait for opencode to be ready
echo "Waiting for opencode to start..."
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:4096 > /dev/null 2>&1; then
        echo "OpenCode is ready."
        break
    fi
    sleep 1
done

# Start nginx in foreground
echo "Starting nginx..."
nginx -g "daemon off;"
EOF
RUN chmod +x /entrypoint.sh

# Set proper permissions for workspace
RUN chown -R opencode:opencode /home/opencode/workspace

# NOTE: Running as root so nginx can bind to port 8080
# opencode itself still writes to /home/opencode

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
CMD []
