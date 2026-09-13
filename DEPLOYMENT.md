# PODVIEW Deployment

## Architecture

```
PODVIEW push (dev/uat/main)       ─┐
                                    ├─ repository_dispatch("image-updated") ─▶ podeview-infra/.github/workflows/deploy.yml
PODView-API push (dev/uat/main)   ─┘                                             │
                                                                                  ├─ az acr build (Dockerfile here, pulls
                                                                                  │  podview:<env> + podview-api:<env> from ACR)
                                                                                  └─ az webapp config container set
                                                                                       → podview-app-<env>
```

Each app repo keeps building and pushing **its own** image to `podviewacr` exactly as it does
today (`podview:<env>` / `podview-api:<env>`, plus a `:<sha>` tag) and keeps deploying to its
own existing target (Container App or App Service — unchanged, see **What still runs
separately** below). The only thing each repo's workflow gains is one extra step: after its own
build+deploy finishes, it fires a `repository_dispatch` telling podeview-infra a new image
landed. podeview-infra then builds the *consolidated* image (this repo's `Dockerfile`, which
pulls both already-built images from ACR — see `README.md`) and rolls it out to one shared
App Service per environment.

Whichever repo's push triggered the run, the consolidated build always pulls **both** services'
current `:<env>` tag — so a UI-only push still picks up the API's latest build for that
environment, and vice versa.

### Deploy targets

| Environment | Consolidated App Service | Plan |
|---|---|---|
| dev | `podview-app-dev` **← new** | `podview-app-dev-plan` **← new** |
| uat | `podview-app-uat` **← new** | `podview-app-uat-plan` **← new** |
| prod | `podview-app-prod` **← new** | `podview-app-prod-plan` **← new** |

None of these reuse an existing name on purpose:

- `podview-dev` already exists as an App Service, but it's managed by `podview-terraform`
  (`dev.tfvars` pins its image to `podview-api:dev`). Deploying a different image to it outside
  Terraform would just get reverted on the next `terraform apply` — Terraform would see drift
  and "fix" it back. A fresh name avoids that fight entirely.
- `podview-uat` / `podview-api-uat` / `podview-api-prod` are Container Apps, a different Azure
  resource type — can't be repointed to an App Service deployment in place.
- The old `podview-prod` App Service is the legacy zip-deploy target (see below) — reusing its
  name for a container deployment would mean two different things sharing one name at different
  points in time, which is exactly the kind of ambiguity worth avoiding.

## What still runs separately (unchanged, not decommissioned by this)

- `podview-dev` (App Service, API only), `podview-uat` / `podview-prod` (Container Apps, UI
  only), `podview-api-uat` / `podview-api-prod` (Container Apps, API only), and the legacy
  zip-deploy of `podview-prod`.

These keep receiving deploys because nothing here removed their steps — only added to them. Once
`podview-app-dev/uat/prod` are confirmed working end to end, decommissioning the old targets
(and removing `AZURE_CREDENTIALS` from the app repos, since only podeview-infra needs it once
the old direct-deploy steps are also removed) is a deliberate follow-up, not automatic.

## Required GitHub secrets

### In `podeview-infra`

| Secret | Description |
|---|---|
| `AZURE_CREDENTIALS` | Service principal JSON for `azure/login@v2`, scoped to `podview-rg` |

### In `PODVIEW` and `PODView-API` (both, new)

| Secret | Description |
|---|---|
| `INFRA_DISPATCH_TOKEN` | PAT with write access to `PODTECH-IO/podeview-infra`'s Actions, just to POST to its `/dispatches` endpoint. Can be the same token in both repos. |

## One-time setup: the three consolidated App Services

Repeat per environment (`dev` / `uat` / `prod`):

```bash
az login
az account set --subscription "<subscription-id>"

ENV=dev   # or uat / prod

az appservice plan create \
  --resource-group podview-rg \
  --name "podview-app-$ENV-plan" \
  --sku B1 --is-linux

az webapp create \
  --resource-group podview-rg \
  --plan "podview-app-$ENV-plan" \
  --name "podview-app-$ENV" \
  --deployment-container-image-name "podviewacr.azurecr.io/podview-consolidated:$ENV"

ACR_PASSWORD=$(az acr credential show --name podviewacr --query "passwords[0].value" -o tsv)
az webapp config container set \
  --name "podview-app-$ENV" \
  --resource-group podview-rg \
  --container-image-name "podviewacr.azurecr.io/podview-consolidated:$ENV" \
  --container-registry-url https://podviewacr.azurecr.io \
  --container-registry-user podviewacr \
  --container-registry-password "$ACR_PASSWORD"

az webapp config appsettings set \
  --name "podview-app-$ENV" \
  --resource-group podview-rg \
  --settings WEBSITES_PORT=8080
```

`podview-consolidated:$ENV` won't exist in ACR until `deploy.yml` runs at least once (either
via a real push to one of the app repos, or manually — see below), so the `az webapp create`
above will fail to pull an image on its first start until that happens. That's expected; create
the App Service first, then trigger a build.

### App settings the consolidated container needs

Both services still read their own env vars — the consolidated image doesn't change what
PODVIEW or PODView-API expect, just how they're reached (nginx now sits in front of both,
routing `/api/*` to the API and everything else to the UI — see `README.md`). Set the union of
what each already needs today as App Service settings (`az webapp config appsettings set`), the
same values already used for `podview-dev` (API) and documented in `podview-terraform`'s
`dev.tfvars`, plus PODVIEW's own (`DATABASE_URL`, `JWT_SECRET`, `MAILGUN_*`, `APP_URL`).

One consequence of consolidating: PODVIEW's client code needs to call `/api/...` with a
**relative** URL for this to work, not the absolute cross-origin base URL introduced in
PODView-API's [ADR 0006](https://github.com/PODTECH-IO/PODView-API/blob/main/docs/adr/0006-client-calls-this-service-directly.md).
Flagged here again because it's easy to ship the infra side of this and still have the client
silently calling the old separate origin.

## Manually triggering a consolidated rebuild

From podeview-infra's Actions tab, run `deploy.yml` with the `environment` input — useful to
pick up a new image without waiting for the next push, or to retry a failed deploy.
