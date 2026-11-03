# demo-api: multi-stage, только runtime-зависимости в образе, запуск под непривилегированным node.
# Базовый образ alpine (не distroless): дриллу OOMKilled нужен node/sh в поде.
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src

FROM node:22-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /app /app
USER node
EXPOSE 8080
CMD ["node", "src/server.js"]