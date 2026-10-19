FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force
COPY index.js ./
RUN mkdir -p /data/feedback
CMD ["node", "index.js"]
