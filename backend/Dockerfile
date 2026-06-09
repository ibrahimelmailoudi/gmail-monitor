# Backend Dockerfile for SnapDeploy (Node + Express + Socket.io + IMAP watchers)
FROM node:20-alpine

WORKDIR /app

# install deps first (better layer caching)
COPY package*.json ./
RUN npm install --omit=dev

# copy the rest of the backend
COPY . .

# SnapDeploy provides PORT via env; our config reads process.env.PORT
EXPOSE 4000

CMD ["npm", "start"]
