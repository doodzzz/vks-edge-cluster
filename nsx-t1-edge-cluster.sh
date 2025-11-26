#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration
# =========================

# NSX Manager connection
NSX_MANAGER="${NSX_MANAGER:-nsx-mgr.lab.local}"
NSX_USER="${NSX_USER:-admin}"
NSX_PASS="${NSX_PASS:-VMware1!}"

# Site / Enforcement Point for edge-cluster listing
SITE_ID="${SITE_ID:-default}"
ENFORCEMENT_POINT_ID="${ENFORCEMENT_POINT_ID:-default}"

BASE_URL="https://${NSX_MANAGER}"
AUTH_CRED="${NSX_USER}:${NSX_PASS}"

# Debug logging
DEBUG="${NSX_DEBUG:-0}"
LOG_FILE="./nsx_api_debug.log"

# =========================
# Helper functions
# =========================

usage() {
  cat <<EOF
Usage:
  $0 [--debug] <command> [args]

Commands:
  list
      List Tier-1 gateways with protection, Edge Cluster association, and NAT status.

  list-edge-clusters
      List Edge Clusters for the configured SITE_ID and ENFORCEMENT_POINT_ID.

  change-edge-cluster <tier1-id> <edge-cluster-path> [<locale-service-id>]
      Change the Edge Cluster for a Tier-1 gateway (attach or move).

  attach-edge-cluster <tier1-id> <edge-cluster-path> [<locale-service-id>]
      Explicit alias for change-edge-cluster.

  detach-edge-cluster <tier1-id> [<locale-service-id>]
      Detach the Tier-1 gateway from its Edge Cluster by clearing edge_cluster_path
      on the Locale Service.

Environment variables:
  NSX_MANAGER            NSX Manager hostname or IP (default: nsx-mgr.lab.local)
  NSX_USER               NSX username              (default: admin)
  NSX_PASS               NSX password              (default: VMware1!)
  SITE_ID                Site ID for edge clusters (default: default)
  ENFORCEMENT_POINT_ID   Enforcement point ID      (default: default)
  NSX_DEBUG              Set to 1 to enable debug logging to ${LOG_FILE}

Examples:
  $0 list
  $0 list-edge-clusters
  $0 change-edge-cluster t1-gw-01 /infra/sites/default/enforcement-points/default/edge-clusters/edge-cluster-01
  $0 detach-edge-cluster t1-gw-01
EOF
}

# Single wrapper for all NSX API calls.
# - Adds auth, JSON headers
# - Adds X-Allow-Overwrite: true on all modifying methods (POST/PUT/PATCH/DELETE)
# - When DEBUG=1, logs method, URL, body and response to LOG_FILE
nsx_curl() {
  local method="$1"
  local url="$2"
  local data="${3:-}"

  local curl_args=(-s -k -u "${AUTH_CRED}" -H "Content-Type: application/json" -X "${method}")

  case "${method}" in
    POST|PUT|PATCH|DELETE)
      curl_args+=(-H "X-Allow-Overwrite: true")
      ;;
  esac

  if [[ -n "${data}" ]]; then
    curl_args+=(-d "${data}")
  fi

  if [[ "${DEBUG}" == "1" ]]; then
    {
      echo "==== $(date '+%Y-%m-%d %H:%M:%S') ===="
      echo "METHOD: ${method}"
      echo "URL   : ${url}"
      if [[ -n "${data}" ]]; then
        echo "BODY  : ${data}"
      fi
      echo "----- RESPONSE -----"
    } >> "${LOG_FILE}"
    # Log and also output to stdout for the caller
    curl "${curl_args[@]}" "${url}" 2>>"${LOG_FILE}" | tee -a "${LOG_FILE}"
  else
    curl "${curl_args[@]}" "${url}"
  fi
}

get_protection() {
  local url="$1"
  nsx_curl "GET" "${url}" | jq -r '._protection // "UNKNOWN"'
}

# Return "PRESENT", "NONE", or "UNKNOWN"
check_nat_rules() {
  local t1_id="$1"
  local nat_base_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}/nat"

  local nat_json
  nat_json="$(nsx_curl "GET" "${nat_base_url}")" || { echo "UNKNOWN"; return 0; }

  local nat_count
  nat_count="$(echo "${nat_json}" | jq '.results | length' 2>/dev/null || echo "0")"

  if [[ "${nat_count}" -eq 0 ]]; then
    echo "NONE"
    return 0
  fi

  # Iterate over NAT services and see if any has NAT rules
  while read -r nat_id; do
    local rules_url="${nat_base_url}/${nat_id}/nat-rules"
    local rules_json
    rules_json="$(nsx_curl "GET" "${rules_url}")" || continue
    local rule_count
    rule_count="$(echo "${rules_json}" | jq '.results | length' 2>/dev/null || echo "0")"
    if [[ "${rule_count}" -gt 0 ]]; then
      echo "PRESENT"
      return 0
    fi
  done < <(echo "${nat_json}" | jq -r '.results[].id')

  echo "NONE"
}

# =========================
# Core functions
# =========================

list_tier1_gateways() {
  local t1_url="${BASE_URL}/policy/api/v1/infra/tier-1s"
  local t1_json
  t1_json="$(nsx_curl "GET" "${t1_url}")"

  echo "Listing Tier-1 gateways, Edge Cluster associations, and NAT status"
  echo "=================================================================="

  echo "${t1_json}" | jq -r '.results[] | @base64' | while read -r t1_b64; do
    _t1() { echo "${t1_b64}" | base64 --decode | jq -r "$1"; }

    local t1_id t1_name t1_protection
    t1_id="$(_t1 '.id')"
    t1_name="$(_t1 '.display_name')"
    t1_protection="$(_t1 '._protection // "UNKNOWN"')"

    echo "TIER1_ID      : ${t1_id}"
    echo "DISPLAY_NAME  : ${t1_name}"
    echo "PROTECTION    : ${t1_protection}"

    # Edge Cluster info via Locale Services
    local ls_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}/locale-services"
    local ls_json
    ls_json="$(nsx_curl "GET" "${ls_url}")"

    local ls_count
    ls_count="$(echo "${ls_json}" | jq '.results | length' 2>/dev/null || echo "0")"

    if [[ "${ls_count}" -eq 0 ]]; then
      echo "EDGE_CLUSTER  : NONE (no locale services)"
    else
      echo "${ls_json}" | jq -r '.results[] | "EDGE_CLUSTER  : \(.edge_cluster_path // "NONE") (ls-id=\(.id))"'
    fi

    # NAT status
    local nat_status
    nat_status="$(check_nat_rules "${t1_id}")"
    echo "NAT_RULES     : ${nat_status}"

    echo "------------------------------------------------------------"
  done
}

list_edge_clusters() {
  local ec_url="${BASE_URL}/policy/api/v1/infra/sites/${SITE_ID}/enforcement-points/${ENFORCEMENT_POINT_ID}/edge-clusters"
  local ec_json
  ec_json="$(nsx_curl "GET" "${ec_url}")"

  echo "Listing Edge Clusters (site=${SITE_ID}, enforcement-point=${ENFORCEMENT_POINT_ID})"
  echo "==============================================================================="

  echo "${ec_json}" | jq -r '.results[] | "ID           : \(.id)\nDISPLAY_NAME : \(.display_name)\nPATH         : \(.path)\nMEMBERS      : \(.members | length)\n------------------------------------------------------------"'
}

# Change (attach/move) Edge Cluster for a Tier-1
change_t1_edge_cluster() {
  local t1_id="$1"
  local edge_cluster_path="$2"
  local locale_service_id="${3:-}"

  echo "Changing Edge Cluster:"
  echo "  Tier-1 ID        : ${t1_id}"
  echo "  Edge Cluster Path: ${edge_cluster_path}"

  # Discover Locale Service if not provided
  if [[ -z "${locale_service_id}" ]]; then
    echo "Discovering Locale Service for Tier-1 '${t1_id}'..."
    local ls_list_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}/locale-services"
    local ls_list_json
    ls_list_json="$(nsx_curl "GET" "${ls_list_url}")"

    locale_service_id="$(echo "${ls_list_json}" | jq -r '.results[0].id')"
    if [[ -z "${locale_service_id}" || "${locale_service_id}" == "null" ]]; then
      echo "ERROR: No Locale Services found for Tier-1 '${t1_id}'."
      exit 1
    fi
    echo "Using Locale Service: ${locale_service_id}"
  fi

  local ls_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}/locale-services/${locale_service_id}"
  local t1_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}"

  echo "Fetching existing Locale Service JSON..."
  local ls_json
  ls_json="$(nsx_curl "GET" "${ls_url}")"

  local t1_protection ls_protection
  t1_protection="$(get_protection "${t1_url}")"
  ls_protection="$(echo "${ls_json}" | jq -r '._protection // "UNKNOWN"')"

  echo "Tier-1 _protection       : ${t1_protection}"
  echo "LocaleService _protection: ${ls_protection}"

  # Build full updated Locale Service payload (preserve revision and other fields)
  local updated_ls
  updated_ls="$(echo "${ls_json}" | jq --arg ec "${edge_cluster_path}" 'del(._links) | .edge_cluster_path = $ec')"

  echo "Attaching Edge Cluster on Locale Service '${locale_service_id}'..."
  nsx_curl "PUT" "${ls_url}" "${updated_ls}" >/dev/null

  echo "Done. Verify with:"
  echo "  ${0} list"
}

# Detach Edge Cluster for a Tier-1
detach_t1_edge_cluster() {
  local t1_id="$1"
  local locale_service_id="${2:-}"

  echo "Detaching Edge Cluster:"
  echo "  Tier-1 ID : ${t1_id}"

  # Discover Locale Service if not provided
  if [[ -z "${locale_service_id}" ]]; then
    echo "Discovering Locale Service for Tier-1 '${t1_id}'..."
    local ls_list_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}/locale-services"
    local ls_list_json
    ls_list_json="$(nsx_curl "GET" "${ls_list_url}")"

    locale_service_id="$(echo "${ls_list_json}" | jq -r '.results[0].id')"
    if [[ -z "${locale_service_id}" || "${locale_service_id}" == "null" ]]; then
      echo "No Locale Services found for Tier-1 '${t1_id}'. Nothing to detach."
      return 0
    fi
    echo "Using Locale Service: ${locale_service_id}"
  fi

  local ls_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}/locale-services/${locale_service_id}"
  local t1_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}"

  echo "Fetching existing Locale Service JSON..."
  local ls_json
  ls_json="$(nsx_curl "GET" "${ls_url}")"

  local t1_protection ls_protection
  t1_protection="$(get_protection "${t1_url}")"
  ls_protection="$(echo "${ls_json}" | jq -r '._protection // "UNKNOWN"')"

  echo "Tier-1 _protection       : ${t1_protection}"
  echo "LocaleService _protection: ${ls_protection}"

  # Build payload with edge_cluster_path cleared
  local updated_ls
  updated_ls="$(echo "${ls_json}" | jq 'del(._links) | .edge_cluster_path = null')"

  echo "Detaching Edge Cluster from Locale Service '${locale_service_id}'..."
  nsx_curl "PUT" "${ls_url}" "${updated_ls}" >/dev/null

  echo "Done. Verify with:"
  echo "  ${0} list"
}

# =========================
# Main
# =========================

main() {
  # Handle optional --debug flag
  if [[ "${1:-}" == "--debug" ]]; then
    DEBUG=1
    # Truncate existing log
    : > "${LOG_FILE}"
    shift
  fi

  local cmd="${1:-}"

  if [[ -z "${cmd}" ]]; then
    usage
    exit 1
  fi

  case "${cmd}" in
    list)
      list_tier1_gateways
      ;;
    list-edge-clusters)
      list_edge_clusters
      ;;
    change-edge-cluster)
      if [[ $# -lt 3 ]]; then
        echo "ERROR: Missing arguments."
        usage
        exit 1
      fi
      change_t1_edge_cluster "$2" "$3" "${4:-}"
      ;;
    attach-edge-cluster)
      if [[ $# -lt 3 ]]; then
        echo "ERROR: Missing arguments."
        usage
        exit 1
      fi
      change_t1_edge_cluster "$2" "$3" "${4:-}"
      ;;
    detach-edge-cluster)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: Missing arguments."
        usage
        exit 1
      fi
      detach_t1_edge_cluster "$2" "${3:-}"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
