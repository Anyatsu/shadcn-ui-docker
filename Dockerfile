FROM node:20-alpine AS alpine

# setup pnpm on the alpine base
FROM alpine as base
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable
RUN pnpm install turbo@1 --global

FROM base AS builder
# Check https://github.com/nodejs/docker-node/tree/b4117f9333da4138b03a546ec926ef50a31506c3#nodealpine to understand why libc6-compat might be needed.
RUN apk add --no-cache libc6-compat
RUN apk add --no-cache git
RUN apk update
# Set working directory
WORKDIR /app
RUN git clone https://github.com/shadcn-ui/ui.git .
RUN turbo prune --scope=www --docker

# Add lockfile and package.jsons of isolated subworkspace
FROM base AS installer
RUN apk add --no-cache libc6-compat
RUN apk update
WORKDIR /app

# First install the dependencies (as they change less often)
COPY --from=builder /app/out/json/ .
COPY --from=builder /app/out/pnpm-lock.yaml ./pnpm-lock.yaml
COPY --from=builder /app/out/pnpm-workspace.yaml ./pnpm-workspace.yaml
RUN pnpm install

# Build the project
COPY --from=builder /app/out/full/ .
COPY --from=builder /app/turbo.json turbo.json
COPY --from=builder /app/tsconfig.json ./tsconfig.json
COPY --from=builder /app/postcss.config.cjs ./postcss.config.cjs
COPY --from=builder /app/tailwind.config.cjs ./tailwind.config.cjs

# Add standalone output to next config
RUN sed -i '/^const nextConfig = {/{N; s/{/{\noutput: '\''standalone'\'',/;}' apps/www/next.config.mjs

RUN turbo build --filter=www

# use alpine as the thinest image
FROM alpine AS runner
WORKDIR /app

# Don't run production as root
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs
USER nextjs

COPY --from=installer /app/apps/www/next.config.mjs .
COPY --from=installer /app/apps/www/package.json .

# Automatically leverage output traces to reduce image size
# https://nextjs.org/docs/advanced-features/output-file-tracing
COPY --from=installer --chown=nextjs:nodejs /app/apps/www/.next/standalone ./
COPY --from=installer --chown=nextjs:nodejs /app/apps/www/.next/static ./apps/www/.next/static
COPY --from=installer --chown=nextjs:nodejs /app/apps/www/public ./apps/www/public

CMD node apps/www/server.js
