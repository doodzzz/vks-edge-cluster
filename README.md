# NSX Edge Cluster Utility

A Bash-based automation utility for VMware NSX (validated on **NSX
4.2.1.0**) that enables administrators to:

-   List all **Tier-1 Gateways**, including their protection status and
    associated Edge Cluster.
-   List all **Edge Clusters** for a given Site and Enforcement Point.
-   Change the **Edge Cluster association** of a Tier-1 Gateway by
    updating its Locale Service.
-   Automatically apply `X-Allow-Overwrite: true` when working with
    protected Policy objects.

This tool is designed for NSX environments where managing multiple
Tier-1 gateways and Edge Cluster migrations is a common operational
task.

## 🚀 Features

### ✔ List Tier-1 Gateways

Displays: - Tier-1 ID\
- Display Name\
- Protection Status\
- Associated Edge Cluster (clean readable formatting)

API Used:

    GET /policy/api/v1/infra/tier-1s

### ✔ List Edge Clusters

Retrieves all Edge Clusters under the configured Site and Enforcement
Point:

    /infra/sites/<site-id>/enforcement-points/<ep-id>/edge-clusters

Displays: - Edge Cluster ID\
- Display Name\
- Policy Path\
- Member Count

### ✔ Change Tier-1 Edge Cluster

Updates the Tier-1's Locale Service to point to a different Edge
Cluster.

The script: - Auto-detects the Locale Service ID (unless manually
provided) - Inspects `_protection` status on both Tier-1 and Locale
Service - Automatically applies:

    X-Allow-Overwrite: true

## 📂 Requirements

-   Bash 4+
-   `curl`
-   `jq`
-   Access to VMware NSX Manager (Policy API)
-   Tested on: **VMware NSX 4.2.1.0**

## ⚙️ Environment Variables

You may override defaults using:

    export NSX_MANAGER="nsx-mgr.lab.local"
    export NSX_USER="admin"
    export NSX_PASS="VMware1!"
    export SITE_ID="default"
    export ENFORCEMENT_POINT_ID="default"

## 📄 Usage

Make the script executable:

    chmod +x nsx-t1-edge-cluster.sh

### 🔍 List Tier-1 Gateways

    ./nsx-t1-edge-cluster.sh list

### 🧭 List Edge Clusters

    ./nsx-t1-edge-cluster.sh list-edge-clusters

### 🔄 Change Tier-1 Edge Cluster

    ./nsx-t1-edge-cluster.sh change-edge-cluster <t1-id> <edge-cluster-path>

Example:

    ./nsx-t1-edge-cluster.sh change-edge-cluster t1-gw-01   /infra/sites/default/enforcement-points/default/edge-clusters/edge-cluster-01

With explicit Locale Service:

    ./nsx-t1-edge-cluster.sh change-edge-cluster t1-gw-01   /infra/sites/default/enforcement-points/default/edge-clusters/edge-cluster-02   ls-01

## 🛡 Protection Awareness

The script reads `_protection` on: - Tier-1 Gateway\
- Locale Service

If either is `PROTECTED` or `REQUIRE_OVERRIDE`, it automatically adds:

    X-Allow-Overwrite: true

## 📝 Notes

-   Fully compliant with VMware NSX Policy API\
-   Output optimized for readability even with long Edge Cluster paths\

## 📘 License

MIT License --- free to use, modify, and distribute.
