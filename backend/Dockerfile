# Hearth relay — multi-stage build: esbuild bundle → distroless runtime.
# No shell, no package manager, no attack surface in the final image.

# --- Stage 1: build ---
FROM node:24-alpine AS build

RUN corepack enable && corepack prepare pnpm@11.3.0 --activate

WORKDIR /app

# Dependencies (cached layer).
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

# Source.
COPY tsconfig.json ./
COPY src ./src

# Bundle to a single ESM file. All deps are pure JS — no native addons.
RUN npx esbuild src/dev-server.ts \
      --bundle \
      --platform=node \
      --format=esm \
      --target=node24 \
      --outfile=dist/server.mjs \
      --external:dotenv

# dotenv is the only runtime dep that reads .env from disk (optional in prod).
# Include it as a node_modules entry for the import to resolve.
RUN mkdir -p dist/node_modules && \
    cp -r node_modules/dotenv dist/node_modules/dotenv

# --- Stage 2: runtime (distroless, no shell) ---
FROM gcr.io/distroless/nodejs24-debian12

WORKDIR /app

COPY --from=build /app/dist ./

ENV PORT=8787
EXPOSE 8787

# Distroless runs as non-root (uid 65534) by default.
CMD ["server.mjs"]
