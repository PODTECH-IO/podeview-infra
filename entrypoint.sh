#!/bin/sh
set -e

# Azure App Service's persistent log mount
mkdir -p /home/LogFiles/pm2

echo "Starting PODVIEW consolidated deployment..."

# Render nginx.conf.template — defaults match ecosystem.config.js, overridable without a rebuild
: "${API_UPSTREAM:=127.0.0.1:4001}"
: "${UI_UPSTREAM:=127.0.0.1:4000}"
export API_UPSTREAM UI_UPSTREAM

echo "Substituting nginx environment variables..."
envsubst '${API_UPSTREAM} ${UI_UPSTREAM}' \
  < /etc/nginx/conf.d/default.conf.template \
  > /etc/nginx/conf.d/default.conf

echo "Testing nginx config..."
nginx -t

echo "Starting nginx..."
nginx -g 'daemon off;' &

# Azure injects PORT to match the container's exposed port (8080, which nginx above is
# already bound to) — unset it before PM2 starts so it doesn't leak into podview-ui's and
# podview-api's own process env and override the ports fixed in ecosystem.config.js.
unset PORT

echo "Starting PM2 services..."
cd /app
exec pm2-runtime start ecosystem.config.js
