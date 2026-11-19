# syntax=docker/dockerfile:1.7

FROM node:24.22.3-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0 AS node-runtime

FROM python:3.13-slim-trixie@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 AS runtime

COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=node-runtime /usr/local/include/node /usr/local/include/node
COPY --from=node-runtime /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=node-runtime /usr/local/share/doc/node /usr/local/share/doc/node
RUN ln -s /usr/local/bin/node /usr/local/bin/nodejs \
  && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack \
  && ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

COPY --from=ghcr.io/astral-sh/uv:latest@sha256:d3b601f0c7b118bc1753febf7c41cc80981df678445e0254284eecf84db79a7d /uv /uvx /bin/

# procps provides `ps`, which tree-kill needs to walk stdio process trees
# (missing it caused spawn ps ENOENT crashes — issue #1072)
RUN apt-get update && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends curl git build-essential procps \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Keep pnpm available for user-supplied runtime commands without retaining
# Corepack's build-time cache in the production image.
RUN npm install --global npm@12.2.3 \
  && npm install --global pnpm@10.34.9 \
  && pnpm config set --global manage-package-manager-versions false \
  && npm cache clean --force

ENV RUSTUP_HOME=/usr/local/rustup \
  CARGO_HOME=/usr/local/cargo \
  PATH=/usr/local/cargo/bin:$PATH

ARG INSTALL_EXT=false
RUN if [ "$INSTALL_EXT" = "true" ]; then \
  ARCH=$(uname -m); \
  if [ "$ARCH" = "x86_64" ]; then \
  npx -y playwright install --with-deps chrome firefox; \
  else \
  echo "Skipping Chrome and Firefox installation on non-amd64 architecture: $ARCH"; \
  fi; \
  # Install Rust toolchain and Docker Engine (includes CLI and daemon) \
  apt-get update && \
  apt-get install -y ca-certificates curl iptables && \
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal && \
  cargo --version && rustc --version && \
  install -m 0755 -d /etc/apt/keyrings && \
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
  chmod a+r /etc/apt/keyrings/docker.asc && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
  apt-get update && \
  apt-get install -y docker-ce docker-ce-cli containerd.io && \
  apt-get clean && rm -rf /var/lib/apt/lists/*; \
  fi

RUN uv tool install mcp-server-fetch

FROM runtime AS build

# Build with the package-manager version declared by package.json. This stage,
# including its package-manager cache and development dependencies, is not shipped.
RUN npm install --global pnpm@10.12.4

WORKDIR /app

COPY package.json pnpm-lock.yaml .pnpmfile.cjs ./
COPY patches ./patches
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
  pnpm config set store-dir /pnpm/store && pnpm fetch --frozen-lockfile
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
  pnpm config set store-dir /pnpm/store && pnpm install --frozen-lockfile --offline

COPY . .

# Download the latest servers.json from mcpm.sh and replace the existing file
RUN curl -s -f --connect-timeout 10 https://mcpm.sh/api/servers.json -o servers.json || echo "Failed to download servers.json, using bundled version"

RUN pnpm build
RUN pnpm prune --prod
# Keep the legacy path available only for user-mounted configuration.
RUN rm /app/mcp_settings.json

FROM runtime AS final

WORKDIR /app

COPY --from=build /app/package.json /app/pnpm-lock.yaml /app/.pnpmfile.cjs ./
COPY --from=build /app/patches ./patches
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/frontend/dist ./frontend/dist
COPY --from=build /app/bin ./bin
COPY --from=build /app/locales ./locales
COPY --from=build /app/servers.json /app/README.md /app/LICENSE ./

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Launch node directly instead of `pnpm start`: the pnpm shim resolves via
# Corepack, which re-downloads pnpm into the runtime user's HOME cache when the
# image runs as a non-root user, breaking startup in egress-restricted
# environments (#1105).
CMD ["node", "dist/index.js"]
