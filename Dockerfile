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

# Fake xdg-open so opencode web doesn't crash in headless container
RUN printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/xdg-open && \
    chmod +x /usr/local/bin/xdg-open

# Configure nginx as a CSP-fixing reverse proxy for opencode
RUN rm -f /etc/nginx/sites-enabled/default
COPY <<NGINXCONF /etc/nginx/conf.d/opencode.conf
server {
    listen 8080;

    location / {
        proxy_pass http://127.0.0.1:4096;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 10s;
        proxy_send_timeout 60s;
        proxy_read_timeout 86400;
        proxy_intercept_errors off;

        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "script-src 'self' 'wasm-unsafe-eval'; default-src 'self'; connect-src 'self' wss: ws:; img-src 'self' data:; style-src 'self' 'unsafe-inline';" always;
    }
}
NGINXCONF

# Create entrypoint script
COPY <<ENTRYEOF /entrypoint.sh
#!/bin/bash

echo "=== Starting opencode ==="
opencode web --port 4096 --hostname 127.0.0.1 --print-logs 2>&1 &
OPENCODE_PID=$!

# Wait up to 60 seconds for opencode to respond
echo "Waiting for opencode to be ready..."
for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:4096 > /dev/null 2>&1; then
        echo "OpenCode ready after ${i}s"
        break
    fi
    if ! kill -0 $OPENCODE_PID 2>/dev/null; then
        echo "ERROR: opencode process died!"
        wait $OPENCODE_PID
        echo "Exit status: $?"
        exit 1
    fi
    echo "  ...waiting (${i}/60)"
    sleep 1
done

echo "Starting nginx..."
exec nginx -g "daemon off;"
ENTRYEOF

RUN chmod +x /entrypoint.sh

# Set proper permissions for workspace
RUN chown -R opencode:opencode /home/opencode/workspace

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
CMD []
