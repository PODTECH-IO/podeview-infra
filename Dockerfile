# ==============================================================================
# Master Assembly Dockerfile
#
# Assembles the pre-built PODVIEW (UI) and PODView-API images — each built and
# pushed to podviewacr by its own repo's pipeline — into one container that runs
# both behind nginx on a single Azure App Service.
#
# Usage:
#   docker build --build-arg UI_IMAGE=podviewacr.azurecr.io/podview:dev \
#                --build-arg API_IMAGE=podviewacr.azurecr.io/podview-api:dev \
#                -t podview-consolidated:dev .
# ==============================================================================

# Full image references, so the pipeline can pin each source image by digest rather
# than by its mutable per-environment tag. Defaults keep the plain tag-based build working.
ARG UI_IMAGE=podviewacr.azurecr.io/podview:dev
ARG API_IMAGE=podviewacr.azurecr.io/podview-api:dev

# Pull the pre-built artifact images at the exact reference resolved for each service
FROM ${UI_IMAGE}  AS ui
FROM ${API_IMAGE} AS api

# ==============================================================================
# Final production image
# ==============================================================================
FROM node:20-alpine

# gettext provides envsubst, used to render nginx.conf.template at container start
RUN apk add --no-cache nginx gettext && \
    npm install -g pm2

WORKDIR /app

# UI (PODVIEW) — built dist + production node_modules lifted from its own image
COPY --from=ui  /app/dist          ./ui/dist
COPY --from=ui  /app/node_modules  ./ui/node_modules
COPY --from=ui  /app/package.json  ./ui/package.json

# API (PODView-API)
COPY --from=api /app/dist          ./api/dist
COPY --from=api /app/node_modules  ./api/node_modules
COPY --from=api /app/package.json  ./api/package.json

# GIT_SHA is baked into each source image as an ENV var, which COPY --from does not carry
# over — re-declared here so podview-api's /health response keeps reporting a real commit
# instead of falling back to "unknown".
ARG API_GIT_SHA=unknown
ENV API_GIT_SHA=${API_GIT_SHA}

COPY nginx.conf /etc/nginx/nginx.conf
COPY nginx.conf.template /etc/nginx/conf.d/default.conf.template
COPY ecosystem.config.js ./
COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

EXPOSE 8080
CMD ["./entrypoint.sh"]
