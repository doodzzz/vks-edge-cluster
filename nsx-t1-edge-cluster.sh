#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration
# =========================

# Set via environment or edit defaults below
NSX_MANAGER="${NSX_MANAGER:-nsx-mgr.lab.local}"
NSX_USER="${NSX_USER:-admin}"
NSX_PASS="${NSX_PASS:-VMware1!}"

# Default site and enforcement point IDs (adjust if needed)
SITE_ID="${SITE_ID:-default}"
ENFORCEMENT_POINT_ID="${ENFORCEMENT_POINT_ID:-default}"

BASE_URL="https://${NSX_MANAGER}"
AUTH_CRED="${NSX_USER}:${NSX_PASS}"

# Add -k to curl to ignore cert issues in lab environments
CURL_COMMON=(-s -k -u "${AUTH_CRED}" -H "Content-Type: application/json")

# =========================
# Helper functions
# =========================

usage() {
  cat <<EOF
Usage:
  $0 list
      List Tier-1 gateways (ID, name, protection) and show Edge Cluster path on its own line.

  $0 list-edge-clusters
      List available Edge Clusters for the configured site and enforcement point.

  $0 change-edge-cluster <tier1-id> <edge-cluster-path> [<locale-service-id>]
      Change the Edge Cluster for a Tier-1 gateway by updating its Locale Service.

      Examples:
        $0 change-edge-cluster t1-gw-01 \\
           /infra/sites/${SITE_ID}/enforcement-points/${ENFORCEMENT_POINT_ID}/edge-clusters/edge-cluster-01

        $0 change-edge-cluster t1-gw-01 \\
           /infra/sites/${SITE_ID}/enforcement-points/${ENFORCEMENT_POINT_ID}/edge-clusters/edge-cluster-01 \\
           ls-01

Environment variables:
  NSX_MANAGER             NSX Manager hostname or IP (default: nsx-mgr.lab.local)
  NSX_USER                NSX username (default: admin)
  NSX_PASS                NSX password (default: VMware1!)
  SITE_ID                 Site ID for Policy (default: default)
  ENFORCEMENT_POINT_ID    Enforcement Point ID (default: default)
EOF
}

# Get protection flag for a Policy object (Tier-1 or Locale Service)
get_protection() {
  local url="$1"

  curl "${CURL_COMMON[@]}" -X GET "${url}" \
    | jq -r '._protection // "UNKNOWN"'
}

# =========================
# Core functions
# =========================

list_tier1_gateways() {
  local t1_url="${BASE_URL}/policy/api/v1/infra/tier-1s"

  # Get all Tier-1s
  local t1_json
  t1_json="$(curl "${CURL_COMMON[@]}" -X GET "${t1_url}")"

  echo "Tier-1 Gateways and their Edge Cluster associations"
  echo "=================================================="
  echo

  # Loop over tier-1s
  echo "${t1_json}" | jq -r '.results[] | @base64' | while read -r t1_b64; do
    _t1() { echo "${t1_b64}" | base64 --decode | jq -r "$1"; }

    local t1_id t1_name t1_protection
    t1_id=$(_t1 '.id')
    t1_name=$(_t1 '.display_name')
    t1_protection=$(_t1 '._protection // "UNKNOWN"')

    # For each Tier-1, get its locale-services and edge_cluster_path (take first locale service)
    local ls_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}/locale-services"
    local ls_json edge_cluster_path

    ls_json="$(curl "${CURL_COMMON[@]}" -X GET "${ls_url}")"

    edge_cluster_path="$(
      echo "${ls_json}" \
        | jq -r '.results[0].edge_cluster_path // "NONE"'
    )"

    printf "TIER1_ID     : %s\n" "${t1_id}"
    printf "DISPLAY_NAME : %s\n" "${t1_name}"
    printf "PROTECTION   : %s\n" "${t1_protection}"
    printf "EDGE_CLUSTER : %s\n" "${edge_cluster_path}"
    echo "--------------------------------------------------"
  done
}

list_edge_clusters() {
  local ec_url="${BASE_URL}/policy/api/v1/infra/sites/${SITE_ID}/enforcement-points/${ENFORCEMENT_POINT_ID}/edge-clusters"

  local ec_json
  ec_json="$(curl "${CURL_COMMON[@]}" -X GET "${ec_url}")"

  echo "Edge Clusters (site=${SITE_ID}, enforcement-point=${ENFORCEMENT_POINT_ID})"
  echo "====================================================================="
  echo

  echo "${ec_json}" | jq -r '.results[] | @base64' | while read -r ec_b64; do
    _ec() { echo "${ec_b64}" | base64 --decode | jq -r "$1"; }

    local ec_id ec_name ec_path member_count
    ec_id=$(_ec '.id')
    ec_name=$(_ec '.display_name')
    ec_path=$(_ec '.path')
    member_count=$(_ec '.members | length // 0')

    printf "EDGE_CLUSTER_ID   : %s\n" "${ec_id}"
    printf "DISPLAY_NAME      : %s\n" "${ec_name}"
    printf "PATH              : %s\n" "${ec_path}"
    printf "MEMBER_COUNT      : %s\n" "${member_count}"
    echo "--------------------------------------------------"
  done
}

change_t1_edge_cluster() {
  local t1_id="$1"
  local edge_cluster_path="$2"
  local locale_service_id="${3:-}"

  # -------------------------
  # 1. Determine Locale Service ID
  # -------------------------
  if [[ -z "${locale_service_id}" ]]; then
    echo "Discovering Locale Service for Tier-1 '${t1_id}'..."
    local ls_list_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}/locale-services"

    locale_service_id=$(
      curl "${CURL_COMMON[@]}" -X GET "${ls_list_url}" \
        | jq -r '.results[0].id'
    )

    if [[ "${locale_service_id}" == "null" || -z "${locale_service_id}" ]]; then
      echo "ERROR: No Locale Services found for Tier-1 '${t1_id}'."
      exit 1
    fi

    echo "Using Locale Service: ${locale_service_id}"
  fi

  local t1_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}"
  local ls_url="${BASE_URL}/policy/api/v1/infra/tier-1s/${t1_id}/locale-services/${locale_service_id}"

  # -------------------------
  # 2. Determine protection status
  # -------------------------
  echo "Checking protection flags..."

  local t1_protection
  t1_protection="$(get_protection "${t1_url}")"

  local ls_protection
  ls_protection="$(get_protection "${ls_url}")"

  echo "Tier-1 _protection       : ${t1_protection}"
  echo "LocaleService _protection: ${ls_protection}"

  # Decide whether to send X-Allow-Overwrite: true
  declare -a overwrite_header=()
  if [[ "${t1_protection}" == "PROTECTED" || "${t1_protection}" == "REQUIRE_OVERRIDE" \
     || "${ls_protection}" == "PROTECTED" || "${ls_protection}" == "REQUIRE_OVERRIDE" ]]; then
    echo "Object is protected or requires override; enabling X-Allow-Overwrite: true..."
    overwrite_header=(-H "X-Allow-Overwrite: true")
  fi

  # -------------------------
  # 3. Build minimal Locale Service payload
  # -------------------------
  local payload
  payload="$(jq -n \
    --arg id "${locale_service_id}" \
    --arg ec_path "${edge_cluster_path}" '
      {
        "id": $id,
        "display_name": $id,
        "edge_cluster_path": $ec_path
      }
    ')"

  echo "Updating Locale Service '${locale_service_id}' with edge_cluster_path:"
  echo "  ${edge_cluster_path}"

  # -------------------------
  # 4. PATCH Locale Service
  # -------------------------
  curl "${CURL_COMMON[@]}" "${overwrite_header[@]}" \
    -X PATCH "${ls_url}" \
    -d "${payload}" | jq '.'

  echo "Done. Verify with:"
  echo "  curl -k -u ${AUTH_CRED} -X GET \"${ls_url}\" | jq '.edge_cluster_path, ._protection'"
}

# =========================
# Main
# =========================

main() {
  local cmd="${1:-}"

  case "${cmd}" in
    list|list-t1)
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
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
