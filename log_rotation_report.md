# Kubernetes Cluster Log Rotation and Archival Report

This report outlines the technical architecture and operational workflow of the centralized log management system implemented for the cluster.

---

### 1. Introduction: Log Rotation & Matrix Overview
The cluster utilizes a multi-tier observability strategy. **Promtail** is deployed as a DaemonSet to scrape active pod logs and forward them to **Loki**, while **Prometheus** simultaneously scrapes time-series matrix logs across node and pod levels for real-time visualization in Grafana. Concurrently, Docker manages local rotation to prevent node disk exhaustion, and a custom **Rclone Archiver pipeline** ensures long-term retention by offloading rotated logs to Google Drive.

### 2. Primary Log Storage Paths
Logs are stored on the node and accessible via the following standard paths:
- **Container JSON Logs (Host Path)**:  
  `/var/lib/docker/containers/<container-id>/<container-id>-json.log`  
  *This is the raw source file managed by the Docker logging driver.*
- **Pod/Namespace Logs (Symlinks)**:  
  `/var/log/pods/<namespace>_<pod-name>_<pod-id>/<container-name>/*.log`  
  *These are symbolic links that simplify log discovery by mapping containers to their respective Kubernetes Pods and Namespaces.*

### 3. Active Log Scraping (Promtail)
While Docker and Rclone handle historical logs, **Promtail** is responsible for the live data stream.
- **Scrape Path**: Promtail monitors the host path `/var/log/pods/*/**/*.log`. It uses these symlinks to automatically discover every running container across the cluster.
- **Processing**: It parses the filenames to automatically attach metadata labels such as `namespace`, `pod`, `container`, and `app`. This allows for high-granularity filtering in Grafana.
- **Forwarding**: All scraped logs are immediately pushed to the **Loki** centralized log database (`http://loki:3100`). This ensures that even if a pod or node crashes, the logs remain accessible for debugging.

### 4. Actual Logrotating Location (`/var/lib/docker/containers`)
Actual log rotation occurs directly within the `/var/lib/docker/containers` directory at the node level. This is where Docker holds the primary output for all running processes.

**Example Scenario (WordPress):**
When a WordPress container generates significant traffic, its primary log file (`...-json.log`) grows. Once it hits the configured limit (10MB):
1. Docker renames the current `...-json.log` to `...-json.log.1`.
2. A new, empty `...-json.log` is created for current output.
3. On the next rotation, `...-json.log.1` becomes `...-json.log.2`, and the process repeats.

### 5. Configuration: Size and File Conditions
The log rotation limits are strictly enforced at the **Minikube Profile** level to ensure they persist even if the cluster is stopped or restarted.
- **Configuration Source**: `/home/praveen/.minikube/profiles/minikube/config.json`
- **Condition Settings**:
  - `max-size=10m`: Rotates the file once it reaches 10 Megabytes.
  - `max-file=3`: Maintains a total of 3 files locally (1 active, 2 rotated).

This configuration is automatically injected into the node's `/etc/docker/daemon.json` by the Minikube hypervisor during boot.

### 6. Management of "Old" Logs (Overflow)
When the "max-file" limit of 3 is reached, Docker would normally delete the oldest file. However, our system intercepts this:
- **The Process**: An **rclone-archiver** pod monitors the `/var/lib/docker/containers` directory on the node.
- **Detection**: It identifies `.log.1` and `.log.2` files immediately after they are rotated.
- **Where they go**: It copies these rotated files into the `/archive` directory inside the `rclone-archiver` pod for temporary staging.

### 7. Post-Archival Workflow (The `/archive` directory)
After logs are moved to the `/archive` directory inside the archiver pod, the following production-ready workflow is triggered:
1. **Compression**: The files are bundled by namespace and application into `.tar.gz` format.
2. **Persistence**: Once the staging area reaches a threshold of **15MB**, the system uses **Rclone** to upload the bundles to Google Drive.
3. **Automatic Purge**: Upon a successful upload, the script deletes the local files within `/archive`, ensuring the pod's storage remains clean.

### 8. Active Performance Scraping (Prometheus Matrix Logs)
Just as Promtail targets active log symlinks, **Prometheus** actively targets distinct API endpoints and exporters to construct real-time matrix logs (time-series metrics). Monitoring is divided across three distinct proxy scopes:

- **1. Container-Level Metrics (cAdvisor)**:
  - **Scrape Path**: Internally queried via the Kubelet proxy at `/api/v1/nodes/<node-name>/proxy/metrics/cadvisor`.
  - **Why We Need It**: cAdvisor provides raw, container-specific statistics (CPU cores, Memory working set, Disk I/O) making it the immediate source of truth when a specific pod (like WordPress or Ghost) experiences intense resource limits.
  
- **2. Cluster-State Metrics (kube-state-metrics)**:
  - **Scrape Path**: Targets the dedicated service endpoint at `kube-state-metrics:8080`.
  - **Why We Need It**: Unlike cAdvisor which watches hardware consumption, `kube-state-metrics` listens to the Kubernetes API. It identifies systemic lifecycle changes like a pod getting `OOMKilled`, repeatedly crashing (Pod Restarts), or getting stuck in a `Pending` phase.

- **3. Node-Level Hardware Metrics (Node-Exporter)**:
  - **Scrape Path**: Deployed as a DaemonSet, scraping underlying host data via `node-exporter:9100`.
  - **Why We Need It**: Bypassing Kubernetes entirely to scrape the underlying Linux kernel stats, this establishes a safety net for absolute Node disk space, total memory limits, and IO bottlenecks.

These aggregated Prometheus matrices are seamlessly unified in Grafana alongside the Loki log streams. If `kube-state-metrics` triggers a high restart count, administrators can simultaneously correlate the exact Memory matrix spike from `cAdvisor` with the fatal crash stack-trace fetched from `Promtail`, deeply refining the troubleshooting workflow.

---
**Status**: Production Ready
**Retention Policy**: 3 local files / 15MB aggregate cloud upload threshold (Logs) | 30-day TSDB memory boundary (Prometheus Matrices).
