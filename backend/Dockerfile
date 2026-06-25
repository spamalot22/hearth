# Hearth relay — the cold-start signalling mailbox + media-search proxies.
# In-memory and stateless; runs the Hono app directly with tsx (no compile step),
# so tsx is a runtime dependency here, not just a dev one.
FROM node:22-alpine

# pnpm via corepack, version pinned by package.json "packageManager".
RUN corepack enable && corepack prepare pnpm@11.3.0 --activate

WORKDIR /app

# Dependencies first — this layer caches unless the lockfile changes. esbuild's
# post-install (tsx needs it) is approved via pnpm-workspace.yaml's
# onlyBuiltDependencies, so a plain install succeeds.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

# App source (tests + .env excluded via .dockerignore — no secrets in the image).
COPY tsconfig.json ./
COPY src ./src

# The platform (Compose / the tunnel) injects PORT; 8787 is the local default.
ENV PORT=8787
EXPOSE 8787

# Drop privileges to the image's built-in non-root user.
USER node

# Run tsx directly (no pnpm process at runtime); tsx caches transpiles to /tmp.
CMD ["node_modules/.bin/tsx", "src/dev-server.ts"]
