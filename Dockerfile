# ── Build stage ──────────────────────────────────────────────
FROM node:24-alpine AS builder
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@latest --activate
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm run build

# ── Runtime stage (distroless) ────────────────────────────────
FROM gcr.io/distroless/nodejs24-debian13 AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/.output ./.output
EXPOSE 3000
CMD ["/app/.output/server/index.mjs"]
