#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" || "${!name}" == "replace_me" || "${!name}" == your_* ]]; then
    printf 'Missing required environment variable: %s\n' "$name" >&2
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

json_post() {
  local url="$1"
  local body="$2"
  curl -fsS "$url" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$body"
}

api_get() {
  local url="$1"
  curl -fsS "$url" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json"
}

write_influx() {
  local payload="$1"

  if [[ -z "$payload" ]]; then
    printf 'No metrics to write.\n' >&2
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s\n' "$payload"
    return 0
  fi

  require_var INFLUX_URL
  require_var INFLUX_ORG
  require_var INFLUX_BUCKET
  require_var INFLUX_TOKEN

  curl -fsS -X POST \
    "${INFLUX_URL%/}/api/v2/write?org=$(jq -rn --arg v "$INFLUX_ORG" '$v|@uri')&bucket=$(jq -rn --arg v "$INFLUX_BUCKET" '$v|@uri')&precision=s" \
    -H "Authorization: Token $INFLUX_TOKEN" \
    -H "Content-Type: text/plain; charset=utf-8" \
    --data-binary "$payload" >/dev/null
}

epoch_seconds() {
  date -u +%s
}

iso_minutes_ago() {
  local minutes="$1"
  date -u -d "$minutes minutes ago" +"%Y-%m-%dT%H:%M:%SZ"
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

fetch_account_storage_metrics() {
  api_get "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/r2/metrics"
}

fetch_graphql_metrics() {
  local start_date="$1"
  local end_date="$2"
  local bucket="${CLOUDFLARE_R2_BUCKET:-}"
  local query filter_bucket variables

  filter_bucket=''
  variables="$(jq -n \
    --arg accountTag "$CLOUDFLARE_ACCOUNT_ID" \
    --arg startDate "$start_date" \
    --arg endDate "$end_date" \
    '{accountTag:$accountTag,startDate:$startDate,endDate:$endDate}')"

  if [[ -n "$bucket" ]]; then
    # shellcheck disable=SC2016
    filter_bucket='bucketName: $bucketName'
    variables="$(jq -n \
      --arg accountTag "$CLOUDFLARE_ACCOUNT_ID" \
      --arg startDate "$start_date" \
      --arg endDate "$end_date" \
      --arg bucketName "$bucket" \
      '{accountTag:$accountTag,startDate:$startDate,endDate:$endDate,bucketName:$bucketName}')"
  fi

  # shellcheck disable=SC2016
  query="$(printf 'query R2Metrics($accountTag: string!, $startDate: Time, $endDate: Time%s) {
  viewer {
    accounts(filter: { accountTag: $accountTag }) {
      r2OperationsAdaptiveGroups(
        limit: 10000
        filter: { datetime_geq: $startDate datetime_leq: $endDate %s }
      ) {
        sum { requests }
        dimensions { bucketName actionType actionStatus responseStatusCode }
      }
      r2StorageAdaptiveGroups(
        limit: 10000
        filter: { datetime_geq: $startDate datetime_leq: $endDate %s }
        orderBy: [datetime_DESC]
      ) {
        max { objectCount uploadCount payloadSize metadataSize }
        dimensions { bucketName datetime }
      }
    }
  }
}' "$(if [[ -n "$bucket" ]]; then printf ', $bucketName: string'; fi)" "$filter_bucket" "$filter_bucket")"

  json_post "https://api.cloudflare.com/client/v4/graphql" \
    "$(jq -n --arg query "$query" --argjson variables "$variables" '{query:$query,variables:$variables}')"
}

account_storage_to_line_protocol() {
  local json="$1"
  local ts="$2"

  jq -r --arg ts "$ts" '
    if (.success == true and .result) then
      .result
      | to_entries[]
      | .key as $class
      | .value
      | to_entries[]
      | .key as $state
      | .value
      | "r2_account_storage,storage_class=\($class),state=\($state) objects=\(.objects // 0)i,payload_size_bytes=\(.payloadSize // 0)i,metadata_size_bytes=\(.metadataSize // 0)i \($ts)"
    else
      empty
    end
  ' <<<"$json"
}

graphql_to_line_protocol() {
  local json="$1"
  local fallback_ts="$2"

  jq -r --arg fallback_ts "$fallback_ts" '
    def tag_escape:
      tostring
      | gsub("\\\\"; "\\\\")
      | gsub(","; "\\,")
      | gsub(" "; "\\ ")
      | gsub("="; "\\=");

    if (.errors // []) | length > 0 then
      halt_error(1)
    else
      .data.viewer.accounts[0] as $account
      | [
          ($account.r2OperationsAdaptiveGroups // [])[]
          | .dimensions as $d
          | "r2_operations,bucket=\(($d.bucketName // "account")|tag_escape),action=\(($d.actionType // "unknown")|tag_escape),status=\(($d.actionStatus // "unknown")|tag_escape),response_status=\(($d.responseStatusCode // "none")|tag_escape) requests=\(.sum.requests // 0)i \($fallback_ts)"
        ],
        [
          ($account.r2StorageAdaptiveGroups // [])[]
          | .dimensions as $d
          | (.dimensions.datetime // null) as $dt
          | "r2_bucket_storage,bucket=\(($d.bucketName // "account")|tag_escape) object_count=\(.max.objectCount // 0)i,upload_count=\(.max.uploadCount // 0)i,payload_size_bytes=\(.max.payloadSize // 0)i,metadata_size_bytes=\(.max.metadataSize // 0)i \(if $dt then ($dt | fromdateiso8601) else $fallback_ts end)"
        ]
      | .[]
      | .[]
    end
  ' <<<"$json"
}

main() {
  require_cmd curl
  require_cmd jq
  require_cmd date
  require_var CLOUDFLARE_ACCOUNT_ID
  require_var CLOUDFLARE_API_TOKEN

  local now_ts start_date end_date account_json graphql_json lines
  now_ts="$(epoch_seconds)"
  start_date="$(iso_minutes_ago "${R2_LOOKBACK_MINUTES:-60}")"
  end_date="$(iso_now)"

  account_json="$(fetch_account_storage_metrics)"
  graphql_json="$(fetch_graphql_metrics "$start_date" "$end_date")"

  lines="$(
    account_storage_to_line_protocol "$account_json" "$now_ts"
    graphql_to_line_protocol "$graphql_json" "$now_ts"
  )"

  write_influx "$lines"
  printf 'R2 metrics collected from %s to %s.\n' "$start_date" "$end_date" >&2
}

main "$@"
