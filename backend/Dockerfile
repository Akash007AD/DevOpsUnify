# ── Build stage ───────────────────────────────────────────────────────────
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install --only=production

# ── Production stage ──────────────────────────────────────────────────────
FROM node:20-alpine
LABEL org.opencontainers.image.source="https://github.com/YOUR_ORG/devopsunify"
LABEL org.opencontainers.image.description="DevOpsUnify API Server"

# Create non-root user
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001

WORKDIR /app

# Copy deps from builder
COPY --from=builder --chown=nodejs:nodejs /app/node_modules ./node_modules

# Copy source
COPY --chown=nodejs:nodejs . .

# Create logs dir
RUN mkdir -p logs && chown nodejs:nodejs logs

USER nodejs

EXPOSE 3000
ENV NODE_ENV=production

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "src/index.js"]
