FROM oven/bun:1.3.14-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssl certbot && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json ./
RUN bun install
COPY relay.ts link.ts ./
RUN mkdir -p /certs /acme && useradd -m app && chown -R app /app /certs /acme
USER app
EXPOSE 8443 8080
CMD ["bun", "run", "relay.ts"]
