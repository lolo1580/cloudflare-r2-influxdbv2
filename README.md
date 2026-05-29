# Cloudflare R2 metrics to InfluxDB v2

Script Bash pour collecter des métriques Cloudflare R2 et les écrire dans InfluxDB v2.

## Prérequis

- `bash`
- `curl`
- `jq`
- `date` GNU compatible

## Configuration

Copier `.env.example` vers `.env`, puis remplir les valeurs :

```bash
cp .env.example .env
```

Variables principales :

- `CLOUDFLARE_ACCOUNT_ID` : ID du compte Cloudflare.
- `CLOUDFLARE_API_TOKEN` : token API Cloudflare.
- `CLOUDFLARE_R2_BUCKET` : optionnel, nom du bucket pour les métriques GraphQL par bucket.
- `INFLUX_URL`, `INFLUX_ORG`, `INFLUX_BUCKET`, `INFLUX_TOKEN` : accès InfluxDB v2.
- `R2_LOOKBACK_MINUTES` : fenêtre de recherche pour les métriques GraphQL.
- `DRY_RUN=1` : affiche le line protocol sans écrire dans InfluxDB.

## Permissions Cloudflare

Le token doit pouvoir lire les métriques R2 du compte. Le script utilise :

- `GET /accounts/{account_id}/r2/metrics`
- `POST /graphql`

Cloudflare expose les métriques R2 via deux jeux de données GraphQL : `r2OperationsAdaptiveGroups` pour les opérations et `r2StorageAdaptiveGroups` pour le stockage. Les métriques GraphQL R2 sont requêtables sur les 31 derniers jours et nécessitent un filtre `accountTag` avec l’ID de compte.

## Utilisation

```bash
chmod +x cloudflare-r2-metrics.sh
./cloudflare-r2-metrics.sh
```

Pour tester sans écrire dans InfluxDB :

```bash
DRY_RUN=1 ./cloudflare-r2-metrics.sh
```

## Mesures InfluxDB

- `r2_account_storage`
  - tags : `storage_class`, `state`
  - fields : `objects`, `payload_size_bytes`, `metadata_size_bytes`

- `r2_operations`
  - tags : `bucket`, `action`, `status`, `response_status`
  - fields : `requests`

- `r2_bucket_storage`
  - tags : `bucket`
  - fields : `object_count`, `upload_count`, `payload_size_bytes`, `metadata_size_bytes`

Sources Cloudflare consultées :

- https://developers.cloudflare.com/api/resources/r2/subresources/buckets/subresources/metrics/methods/list/
- https://developers.cloudflare.com/r2/platform/metrics-analytics/
