# podeview-infra

Consolidates PODVIEW (UI) and PODView-API into one deployable image for Azure App Service,
the same shape as [reportzero-infra](https://github.com/PODTECH-IO/reportzero-infra)'s
consolidated build: each app is built and pushed to `podviewacr` by its own repo's own
pipeline, and this repo's `Dockerfile` pulls both already-built images from ACR and assembles
them into one container that runs both behind nginx via PM2.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage: pulls the images given by `UI_IMAGE` / `API_IMAGE` (digest-pinned by the pipeline) from ACR, lifts each one's `dist/` + production `node_modules` into the final image |
| `ecosystem.config.js` | PM2 process config — `podview-ui` on :4000, `podview-api` on :4001 |
| `nginx.conf` | Main nginx config (events/http block) — ships explicitly because Alpine's own nginx package doesn't wire up `conf.d` the way Debian's does; see the file's own comment |
| `nginx.conf.template` | Reverse proxy on :8080 — `/api/*`, `/api-docs`, `/health`, `/health/db` → podview-api; everything else → podview-ui |
| `entrypoint.sh` | Container startup: renders the nginx template, starts nginx, then `pm2-runtime` in the foreground |

## Routing

podview-api mounts every route under `/api` (including `/api/auth/*`) and its health checks
at root `/health` / `/health/db` (`src/routes.ts`, `src/modules/health`) — nginx forwards both
prefixes there untouched. Everything else falls through to podview-ui, which serves the SPA
and its static assets. This makes the two apps same-origin behind one App Service, so the
client can call `/api/...` with relative URLs.

## Building locally

```bash
docker build \
  --build-arg UI_IMAGE=podviewacr.azurecr.io/podview:dev \
  --build-arg API_IMAGE=podviewacr.azurecr.io/podview-api:dev \
  --build-arg API_GIT_SHA=$(git -C ../PODView-API rev-parse HEAD) \
  -t podview-consolidated:dev .
```

## Automatic builds

`.github/workflows/deploy.yml` rebuilds and redeploys the consolidated image whenever either
app repo pushes a new image to ACR (each repo's own `deploy-*.yml` fires a
`repository_dispatch` after its existing build/deploy step — see `DEPLOYMENT.md`). It also
takes a manual `workflow_dispatch` with an `environment` input.

See [DEPLOYMENT.md](./DEPLOYMENT.md) for the full picture: required secrets, the one-time `az`
setup for the three consolidated App Services (`podview-app-dev/uat/prod` — none of which exist
yet), and why they're new names rather than reusing today's split-deployment resources.

## Releasing to uat/prod

`podview` and `podview-api`'s own `deploy-uat.yml`/`deploy-prod.yml` only build and tag images
(`<env>-<YYYYMMDD>.<N>`, e.g. `uat-20260915.1`) — nothing auto-deploys there, unlike dev.
`.github/workflows/release.yml` is the promotion step, modeled on
[reportzero-infra's release.yml](https://github.com/PODTECH-IO/reportzero-infra/blob/main/.github/workflows/release.yml):
run it manually (`workflow_dispatch`) with an environment and, optionally, a specific tag per
service (blank keeps whatever's currently released). It resolves the versions, builds the
consolidated image pinned to exactly those, deploys it, health-checks it, and commits the result
to `environments/<env>/current-versions.json` so the next release knows what "current" means.
