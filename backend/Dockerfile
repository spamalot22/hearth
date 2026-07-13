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
# Uses server.ts (prod entry, no dotenv — env injected by Docker).
RUN npx esbuild src/server.ts \
      --bundle \
      --platform=node \
      --format=esm \
      --target=node24 \
      --outfile=dist/server.mjs

# --- Stage 2: runtime (distroless, no shell) ---
FROM gcr.io/distroless/nodejs24-debian13:nonroot

WORKDIR /app

COPY --from=build /app/dist ./

ENV PORT=8787
EXPOSE 8787

# The explicit nonroot variant runs as uid 65532.
CMD ["server.mjs"]
