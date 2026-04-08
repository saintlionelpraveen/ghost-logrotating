# Kubernetes Cluster Log Rotation and Archival Report

This report outlines the technical architecture and operational workflow of the centralized log management system implemented for the cluster.

---

### 1. Introduction: Log Rotation Overview
The cluster utilizes a multi-tier log management strategy. Local log rotation is managed by the **Docker engine** to prevent node disk exhaustion, while a custom **Rclone Archiver pipeline** ensures long-term retention by offloading rotated logs to external cloud storage (Google Drive). This hybrid approach provides both high-performance local access and cost-effective historical archiving.

### 2. Primary Log Storage Paths
Logs are stored on the node and accessible via the following standard paths:
- **Container JSON Logs (Host Path)**:  
  `/var/lib/docker/containers/<container-id>/<container-id>-json.log`  
  *This is the raw source file managed by the Docker logging driver.*
- **Pod/Namespace Logs (Symlinks)**:  
  `/var/log/pods/<namespace>_<pod-name>_<pod-id>/<container-name>/*.log`  
  *These are symbolic links that simplify log discovery by mapping containers to their respective Kubernetes Pods and Namespaces.*

### 3. Actual Logrotating Location (`/var/lib/docker/containers`)
Actual log rotation occurs directly within the `/var/lib/docker/containers` directory at the node level. This is where Docker holds the primary output for all running processes.

**Example Scenario (WordPress):**
When a WordPress container generates significant traffic, its primary log file (`...-json.log`) grows. Once it hits the configured limit (10MB):
1. Docker renames the current `...-json.log` to `...-json.log.1`.
2. A new, empty `...-json.log` is created for current output.
3. On the next rotation, `...-json.log.1` becomes `...-json.log.2`, and the process repeats.

### 4. Configuration: Size and File Conditions
The log rotation limits are strictly enforced at the **Minikube Profile** level to ensure they persist even if the cluster is stopped or restarted.
- **Configuration Source**: `/home/praveen/.minikube/profiles/minikube/config.json`
- **Condition Settings**:
  - `max-size=10m`: Rotates the file once it reaches 10 Megabytes.
  - `max-file=3`: Maintains a total of 3 files locally (1 active, 2 rotated).

This configuration is automatically injected into the node's `/etc/docker/daemon.json` by the Minikube hypervisor during boot.

### 5. Management of "Old" Logs (Overflow)
When the "max-file" limit of 3 is reached, Docker would normally delete the oldest file. However, our system intercepts this:
- **The Process**: An **rclone-archiver** pod monitors the `/var/lib/docker/containers` directory on the node.
- **Detection**: It identifies `.log.1` and `.log.2` files immediately after they are rotated.
- **Where they go**: It copies these rotated files into the `/archive` directory inside the `rclone-archiver` pod for temporary staging.

### 6. Post-Archival Workflow (The `/archive` directory)
After logs are moved to the `/archive` directory inside the archiver pod, the following production-ready workflow is triggered:
1. **Compression**: The files are bundled by namespace and application into `.tar.gz` format.
2. **Persistence**: Once the staging area reaches a threshold of **15MB**, the system uses **Rclone** to upload the bundles to Google Drive.
3. **Automatic Purge**: Upon a successful upload, the script deletes the local files within `/archive`, ensuring the pod's storage remains clean.

---
**Status**: Production Ready
**Retention Policy**: 3 local files / 15MB aggregate cloud upload threshold.
