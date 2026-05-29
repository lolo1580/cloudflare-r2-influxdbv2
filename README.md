# Cloudflare R2 Metrics to InfluxDB v2

Bash script to collect Cloudflare R2 metrics and write them to InfluxDB v2.

## Requirements

- `bash`
- `curl`
- `jq`
- GNU-compatible `date`

## Configuration

Copy `.env.example` to `.env`, then fill in the values:

```bash
cp .env.example .env
```

Main variables:

- `CLOUDFLARE_ACCOUNT_ID`: Cloudflare account ID.
- `CLOUDFLARE_API_TOKEN`: Cloudflare API token.
- `CLOUDFLARE_R2_BUCKET`: optional bucket name for per-bucket GraphQL metrics.
- `R2_ACCOUNT_STORAGE_METRICS`: set to `0` to skip the REST account storage endpoint.
- `INFLUX_URL`, `INFLUX_ORG`, `INFLUX_BUCKET`, `INFLUX_TOKEN`: InfluxDB v2 access settings.
- `R2_LOOKBACK_MINUTES`: lookback window for GraphQL metrics.
- `DRY_RUN=1`: prints line protocol without writing to InfluxDB.

## Cloudflare Permissions

The script can use two Cloudflare APIs:

- `POST /graphql` for R2 operations and per-bucket storage metrics. The API token needs account `Analytics Read`.
- `GET /accounts/{account_id}/r2/metrics` for account-level storage totals. The API token needs `Workers R2 Storage Read`. Set `R2_ACCOUNT_STORAGE_METRICS=0` to skip this endpoint if your token only has analytics access.

Cloudflare exposes R2 metrics through two GraphQL datasets: `r2OperationsAdaptiveGroups` for operations and `r2StorageAdaptiveGroups` for storage. GraphQL R2 metrics can be queried for the last 31 days and require an `accountTag` filter with the account ID.

## Usage

```bash
chmod +x cloudflare-r2-metrics.sh
./cloudflare-r2-metrics.sh
```

To test without writing to InfluxDB:

```bash
DRY_RUN=1 ./cloudflare-r2-metrics.sh
```

## systemd Timer

The repository includes a systemd service and timer for running the script every 15 minutes.

```bash
sudo cp systemd/cloudflare-r2-metrics.service /etc/systemd/system/
sudo cp systemd/cloudflare-r2-metrics.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflare-r2-metrics.timer
```

Useful checks:

```bash
systemctl list-timers cloudflare-r2-metrics.timer
systemctl status cloudflare-r2-metrics.service
journalctl -u cloudflare-r2-metrics.service -n 50 --no-pager
```

## InfluxDB Measurements

- `r2_account_storage`
  - tags: `storage_class`, `state`
  - fields: `objects`, `payload_size_bytes`, `metadata_size_bytes`

- `r2_operations`
  - tags: `bucket`, `action`, `status`, `response_status`
  - fields: `requests`

- `r2_bucket_storage`
  - tags: `bucket`
  - fields: `object_count`, `upload_count`, `payload_size_bytes`, `metadata_size_bytes`

Cloudflare sources:

- https://developers.cloudflare.com/api/resources/r2/subresources/buckets/subresources/metrics/methods/list/
- https://developers.cloudflare.com/r2/platform/metrics-analytics/
