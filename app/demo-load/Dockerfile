# demo-load: тот же базовый образ и непривилегированный пользователь, что у demo-api.
FROM node:22.23.4-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src

FROM node:22.23.4-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /app /app
USER 1000:1000
EXPOSE 8080
CMD ["node", "src/load.js"]