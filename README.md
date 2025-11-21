# NSX Tier-1 Edge Cluster Utility

A Bash-based utility script for VMware NSX (tested on **NSX 4.2.1.0**) that provides:

- **Listing of all Tier-1 Gateways**  
  - Includes Tier-1 name, ID, protection status  
  - Displays the associated Edge Cluster path on its own line  

- **Listing of available Edge Clusters**  
  - Enumerates Edge Clusters for a given site and enforcement point  
  - Shows cluster ID, name, path, and member count  

- **Modifying the Edge Cluster association of a Tier-1 Gateway**  
  - Updates the Tier-1’s Locale Service  
  - Automatically applies `X-Allow-Overwrite: true` when objects are protected  


---

## 📌 Features

### ✔ List Tier-1 Gateways
- ID, Display Name, Protection Status  
- Edge Cluster Path printed on a dedicated line (clean formatting)  
- Uses Policy API: `/policy/api/v1/infra/tier-1s`

### ✔ List Edge Clusters
- Lists all Edge Clusters under:
