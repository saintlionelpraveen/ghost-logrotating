# Kubernetes Log Rotation and Archiving: Live Demo and Operations Guide

This document contains all necessary commands and context to successfully demonstrate the Kubernetes centralized log rotation pipeline (Docker + Promtail + Rclone + Google Drive) live to the team.

It also contains critical administrative instructions on maintaining limits across cluster reboots.

---

## 1. The Persistent Minikube Reboot Fix (Production Config)

By default, any custom modifications made directly to `/etc/docker/daemon.json` inside Minikube will be entirely wiped out and reset the moment you run `minikube stop` and `minikube start`.

**To fix this permanently, the limits must be bound to the Minikube Profile Configuration itself.**

### The Fix Path:
The master file is located on your local workstation at:
`/home/praveen/.minikube/profiles/minikube/config.json`

### What was changed:
We updated the `"DockerOpt"` JSON array inside that configuration file to strictly enforce the file and size limits at boot:

```json
	"DockerOpt": [
		"log-opt=max-size=10m",
		"log-opt=max-file=3"
	],
```

Because of this specific fix, whenever you securely restart the cluster via `minikube stop` and `minikube start`, Minikube automatically intercepts these options and safely reconstructs the `/etc/docker/daemon.json` limits correctly upon boot.

---

## 2. Live Demo Flow: The 40MB WordPress Load Test

When presenting to the team, you can actively simulate massive traffic forcing a container to immediately log more than 40MB of data. This rapidly proves the `max-size: 10m` rotation limit, and immediately triggers the Rclone automated offload to Google Drive.

Follow these exact steps:

### Step 1: Open Terminal Port-Forward
First, open access to the WordPress service so we can target it.
```bash
kubectl port-forward svc/wordpress -n log 8889:80 &
```

### Step 2: Flood with Shell Traffic (The "Blast")
Because typical PHP/Apache servers buffer HTTP requests and write incredibly small log entries, HTTP load testers like `hey` can be too slow for a live 5-minute demo. 

The foolproof, instant way to generate 40 Megabytes of raw JSON logs is to map an internal shell script directly to the Docker output descriptor (`fd/1`). 

Run this command directly in your terminal:
```bash
kubectl exec -n log deployment/wordpress -c wordpress -- sh -c 'awk "BEGIN { for (i = 1; i <= 300000; i++) print \"[INFO] WordPress simulated traffic for rotation testing... Line \" i > \"/proc/1/fd/1\" }"'
```

**What this does:**
1. It injects a script into the live WordPress container.
2. It loops 300,000 times, violently writing characters to the standard output bypass limit.
3. The file `/var/lib/docker/containers/.../...json.log` immediately explodes in size to `~45MB`.
4. Docker forcefully slices this into three chunks (`.log`, `.log.1`, `.log.2`).

### Step 3: Verify the Rotation in Action
Show the team that Docker successfully rotated the files on the server node:
```bash
minikube ssh 'WP_CID=$(sudo docker ps --no-trunc -q --filter name=k8s_wordpress_wordpress); sudo find /var/lib/docker/containers/$WP_CID/ -name "*json.log*" -exec ls -lah {} \;'
```

### Step 4: Verify the GDrive Archive Upload
Within 60 seconds of the files rotating, the `rclone-archiver` DaemonSet checks the sizes, tars the rotated chunks, and uploads them. 

Show the team the live logs of the archiver uploading to Google Drive:
```bash
kubectl logs -n log daemonset/rclone-archiver --tail=30
```

Show the team the final `.tar.gz` successfully sitting in the cloud via Rclone:
```bash
kubectl exec -it daemonset/rclone-archiver -n log -- rclone ls n:k8s-logs/ --config /etc/rclone/rclone.conf
```
