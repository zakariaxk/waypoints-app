# Build stage
FROM node:20-alpine AS builder

WORKDIR /app

# Copy root package files and workspace package.jsons
COPY package.json package-lock.json ./
COPY packages/shared/package.json packages/shared/
COPY services/api/package.json services/api/

# Install dependencies (workspace-filtered; typescript now in each workspace)
RUN npm ci --workspace=packages/shared --workspace=services/api

# Copy source code
COPY tsconfig.base.json ./
COPY packages/shared/ packages/shared/
COPY services/api/ services/api/

# Build shared types and API
RUN npm run build -w packages/shared
RUN npm run build -w services/api

# Production stage
FROM node:20-alpine

WORKDIR /app

# Copy package files for production install
COPY package.json package-lock.json ./
COPY packages/shared/package.json packages/shared/
COPY services/api/package.json services/api/

# Install production dependencies only
RUN npm ci --workspace=packages/shared --workspace=services/api --omit=dev

# Copy built output
COPY --from=builder /app/packages/shared/dist/ packages/shared/dist/
COPY --from=builder /app/packages/shared/package.json packages/shared/
COPY --from=builder /app/services/api/dist/ services/api/dist/
COPY --from=builder /app/services/api/package.json services/api/

# Expose port
ENV PORT=8080
ENV HOST=0.0.0.0
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1

# Run the API
CMD ["node", "services/api/dist/index.js"]
