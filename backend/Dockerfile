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

# Seed version manifest (self-heals from GitHub at runtime if stale).
RUN mkdir -p data && echo '{"version":"0.0.0","seq":0,"assets":{},"sig":""}' > data/version.json

# Bundle to a single ESM file. All deps are pure JS — no native addons.
# Uses server.ts (prod entry, no dotenv — env injected by Docker).
RUN npx esbuild src/server.ts \
      --bundle \
      --platform=node \
      --format=esm \
      --target=node24 \
      --outfile=dist/server.mjs

# --- Stage 2: runtime (distroless, no shell) ---
FROM gcr.io/distroless/nodejs24-debian12:latest

WORKDIR /app

COPY --from=build /app/dist ./
# Version manifest (optional — self-heals from GitHub if absent).
COPY --from=build /app/data ./data

ENV PORT=8787
EXPOSE 8787

# Distroless runs as non-root (uid 65534) by default.
CMD ["server.mjs"]
