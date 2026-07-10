# CineRankML-deploy

Kubernetes (k3s) manifests for the CineRankML online stack, managed with Kustomize.

## What this deploys

| Workload | Kind | Notes |
|---|---|---|
| postgres | StatefulSet | Modest memory settings for a single VPS |
| kafka | StatefulSet | Single-node KRaft |
| opensearch | StatefulSet | Security disabled, 512Mi heap |
| minio | StatefulSet | S3-compatible artifact store |
| minio-init | Job | Creates the `cinerankml` bucket |
| migrate | Job | Alembic `upgrade head` (schema) |
| ratings-consumer | Deployment | Kafka → Postgres |
| embedder-api | Deployment | Content embeddings HTTP API |
| recommender-api | Deployment | Online recommendations |
| frontend | Deployment | nginx static UI (prod image) |
| prometheus | Deployment | Scrapes app + exporters (ClusterIP only) |
| grafana | Deployment | Dashboards; Ingress `/grafana` |
| postgres-exporter | Deployment | Custom CineRankML SQL metrics |
| opensearch-exporter | Deployment | OpenSearch index metrics |
| Ingress | Traefik | `/` frontend, `/api` API, `/grafana` Grafana |

**Not deployed here:** ratings-producer, tags workers, catalog/ML jobs, pushgateway, MLflow.

## Layout

```text
base/                 # shared manifests
overlays/prod/        # image tags + VPS resource patches
```

CI (in the app repo, later) should bump `images[].newTag` in
[`overlays/prod/kustomization.yaml`](overlays/prod/kustomization.yaml) to the
CineRankML git SHA after pushing images to GHCR.

## Prerequisites (VPS)

1. Install [k3s](https://docs.k3s.io/).
2. Raise `vm.max_map_count` for OpenSearch:

   ```bash
   sudo sysctl -w vm.max_map_count=262144
   echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf
   ```

3. Create a GHCR pull secret (required for private packages):

   ```bash
   kubectl create namespace cinerankml --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n cinerankml create secret docker-registry ghcr-pull \
     --docker-server=ghcr.io \
     --docker-username=YOUR_GITHUB_USER \
     --docker-password=YOUR_GHCR_PAT \
     --docker-email=YOU@example.com
   ```

4. Create the Secret on the VPS **before** `kubectl apply` (not committed to Git):

   ```bash
   export KUBECONFIG=$HOME/.kube/config
   kubectl create namespace cinerankml --dry-run=client -o yaml | kubectl apply -f -

   POSTGRES_PASSWORD=$(openssl rand -hex 32)
   S3_ACCESS_KEY=$(openssl rand -hex 16)
   S3_SECRET_KEY=$(openssl rand -hex 32)

   kubectl -n cinerankml create secret generic cinerankml-secret \
     --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
     --from-literal=DATABASE_URL="postgresql+psycopg://cinerankml:${POSTGRES_PASSWORD}@postgres:5432/cinerankml" \
     --from-literal=S3_ACCESS_KEY="$S3_ACCESS_KEY" \
     --from-literal=S3_SECRET_KEY="$S3_SECRET_KEY" \
     --from-literal=GF_SECURITY_ADMIN_USER=admin \
     --from-literal=GF_SECURITY_ADMIN_PASSWORD="$(openssl rand -hex 16)" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

   Manifests only reference `secretKeyRef: name: cinerankml-secret`. Do not commit Secret YAML.

   On this VPS, an encrypted backup lives outside Git at `~/apps/secrets/`:

   - `cinerankml-secret.env.enc` + `.encryption-passphrase`
   - `./decrypt.sh` / `./restore-to-cluster.sh`

   Recreate the backup after rotating the cluster Secret:

   ```bash
   # from a machine with the helper script, or re-run the create script on the VPS
   ~/apps/secrets/restore-to-cluster.sh   # restore INTO cluster
   ```

## Apply

```bash
git clone https://github.com/tmir00/CineRankML-deploy.git
cd CineRankML-deploy

# Preview
kubectl kustomize overlays/prod

# Apply
kubectl apply -k overlays/prod
```

Wait for infra, then confirm Jobs:

```bash
kubectl -n cinerankml rollout status statefulset/postgres
kubectl -n cinerankml rollout status statefulset/kafka
kubectl -n cinerankml rollout status statefulset/opensearch
kubectl -n cinerankml rollout status statefulset/minio

kubectl -n cinerankml wait --for=condition=complete job/minio-init --timeout=300s
kubectl -n cinerankml wait --for=condition=complete job/migrate --timeout=300s
```

Re-run a finished Job (e.g. after new migrations):

```bash
kubectl -n cinerankml delete job migrate --ignore-not-found
kubectl apply -k overlays/prod
```

## Hostname and routing

DNS: point `cinerankml.taahaamir.com` A/AAAA at the VPS (Traefik / k3s node).

| Public URL | Backend |
|---|---|
| `https://cinerankml.taahaamir.com/` | frontend |
| `https://cinerankml.taahaamir.com/api/...` | recommender-api (Traefik strips `/api`) |
| `https://cinerankml.taahaamir.com/grafana` | Grafana (subpath) |

Prometheus UI is ClusterIP-only:

```bash
kubectl -n cinerankml port-forward svc/prometheus 9090:9090
```

Scrape jobs: `postgres-exporter`, `ratings-consumer`, `embedder-api`, `recommender-api`, `opensearch-exporter`.

FastAPI has no `/api` prefix (`/health`, `/v1/...`). The `strip-api` Middleware removes
`/api` before the request reaches the pod, so
`/api/v1/recommend` → `/v1/recommend`.

Build the frontend image with:

```text
VITE_RECOMMENDER_API_URL=https://cinerankml.taahaamir.com/api
```

`CORS_ALLOW_ORIGINS` is set to `https://cinerankml.taahaamir.com` in the ConfigMap.
Until TLS is enabled, use the `http://` variants for both CORS and the Vite build arg,
and keep the Ingress on the `web` entrypoint.

## Out-of-band data bootstrap

This cluster does **not** run catalog seed, OpenSearch sync, or training jobs.
Before recommendations work end-to-end you must load data elsewhere (local Docker
Compose jobs) and copy into the VPS:

1. **Schema** — covered by the `migrate` Job.
2. **Catalog / ratings** — restore or seed Postgres (e.g. dump/restore from a local run).
3. **OpenSearch index** — sync locally, then snapshot/restore or re-run sync against the VPS OpenSearch when you add that job later.
4. **Model + CF artifacts** — upload into MinIO bucket `cinerankml` (same layout the API expects under `S3_ENDPOINT_URL`).

Without those, pods may still start, but recommend paths will be empty or degraded.

## Periodic pull (GitOps-lite)

On the VPS, a timer can refresh manifests:

```bash
cd /opt/CineRankML-deploy && git pull && kubectl apply -k overlays/prod
```

## Image names

| Image |
|---|
| `ghcr.io/tmir00/cinerankml-migrate:<sha>` |
| `ghcr.io/tmir00/cinerankml-ratings-consumer:<sha>` |
| `ghcr.io/tmir00/cinerankml-embedder-api:<sha>` |
| `ghcr.io/tmir00/cinerankml-recommender-api:<sha>` |
| `ghcr.io/tmir00/cinerankml-frontend:<sha>` |
