#!/bin/bash
# =============================================================================
# deploy.sh — Idempotent deploy script for the Kubernetes log pipeline
# Run from the log-rotating directory:  bash deploy.sh
# =============================================================================
set -euo pipefail

NS="log"
KUBECTL="kubectl"
LOG_MAX_SIZE="10m"
LOG_MAX_FILE="3"

info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }
step()  { echo -e "\n\033[34m▶ $*\033[0m"; }

# ---------------------------------------------------
step "0/9 — Enforce Docker log rotation limits (persistent)"
# ---------------------------------------------------
# Minikube resets /etc/docker/daemon.json on every restart.
# We install a systemd drop-in that patches daemon.json BEFORE
# Docker reads it, so limits survive minikube stop/start cycles.

# -- One-time install: patch script + systemd drop-in --
DROPIN_INSTALLED=$(minikube ssh "test -f /etc/systemd/system/docker.service.d/log-limits.conf && echo yes" 2>/dev/null)
if [ "$DROPIN_INSTALLED" != "yes" ]; then
  info "Installing persistent systemd drop-in for Docker log limits..."
  minikube ssh "sudo tee /usr/local/bin/patch-docker-log-opts.sh > /dev/null && sudo chmod +x /usr/local/bin/patch-docker-log-opts.sh" << 'SCRIPT'
#!/bin/bash
python3 -c "
import json, os
p = '/etc/docker/daemon.json'
c = json.load(open(p)) if os.path.exists(p) else {}
c['log-opts'] = {'max-size': '10m', 'max-file': '3'}
json.dump(c, open(p, 'w'))
"
SCRIPT
  minikube ssh "sudo mkdir -p /etc/systemd/system/docker.service.d"
  minikube ssh "sudo tee /etc/systemd/system/docker.service.d/log-limits.conf > /dev/null" << 'DROPIN'
[Service]
ExecStartPre=-/usr/local/bin/patch-docker-log-opts.sh
DROPIN
  minikube ssh "sudo systemctl daemon-reload"
  info "Systemd drop-in installed — log limits will auto-apply on every minikube start"
fi

# -- Always verify & patch current session --
CURRENT_MAX_SIZE=$(minikube ssh "cat /etc/docker/daemon.json" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('log-opts',{}).get('max-size',''))" 2>/dev/null || echo "")
CURRENT_MAX_FILE=$(minikube ssh "cat /etc/docker/daemon.json" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('log-opts',{}).get('max-file',''))" 2>/dev/null || echo "")
if [ "$CURRENT_MAX_SIZE" != "$LOG_MAX_SIZE" ] || [ "$CURRENT_MAX_FILE" != "$LOG_MAX_FILE" ]; then
  info "Patching daemon.json: max-size=$LOG_MAX_SIZE, max-file=$LOG_MAX_FILE"
  minikube ssh "sudo /usr/local/bin/patch-docker-log-opts.sh"
  info "Restarting Docker inside Minikube (pods will briefly cycle)..."
  minikube ssh "sudo systemctl restart docker"
  sleep 15
  info "Docker restarted with log limits: max-size=$LOG_MAX_SIZE, max-file=$LOG_MAX_FILE"
else
  info "Docker log limits already correct: max-size=$LOG_MAX_SIZE, max-file=$LOG_MAX_FILE — skipping"
fi

# ---------------------------------------------------
step "1/9 — Namespace + Quota"
# ---------------------------------------------------
$KUBECTL apply -f namespace.yml
$KUBECTL -n $NS wait --for=condition=Ready pods --all --timeout=0s 2>/dev/null || true

# ---------------------------------------------------
step "2/9 — Clean up old Deployments/DaemonSets (if any)"
# ---------------------------------------------------
# These were converted to standalone Pods for clean naming
$KUBECTL -n $NS delete deployment wordpress listmonk mattermost 2>/dev/null || true
$KUBECTL -n $NS delete daemonset promtail rclone-archiver 2>/dev/null || true
info "Old Deployments/DaemonSets cleaned up"

# ---------------------------------------------------
step "3/9 — Secrets"
# ---------------------------------------------------
$KUBECTL apply -f secrets.yml
info "Secrets applied. rclone token expiry is stored in the secret — re-run if GDrive uploads fail."

# ---------------------------------------------------
step "4/9 — Grafana datasource + dashboard"
# ---------------------------------------------------
$KUBECTL apply -f grafana-datasource.yml
$KUBECTL apply -f grafana-dashboard.yml

# ---------------------------------------------------
step "5/9 — App pods (ghost, wordpress, listmonk, mattermost)"
# ---------------------------------------------------
$KUBECTL apply -f ghost-pod.yml
$KUBECTL apply -f wordpress-pod.yml
$KUBECTL apply -f listmonk-pod.yml
$KUBECTL apply -f mattermost-pod.yml

# ---------------------------------------------------
step "6/9 — Promtail Pod"
# ---------------------------------------------------
$KUBECTL apply -f promtail-daemonset.yml

# ---------------------------------------------------
step "7/9 — Rclone Archiver Pod"
# ---------------------------------------------------
$KUBECTL apply -f rclone-archiver.yml

# ---------------------------------------------------
step "8/9 — Waiting for pods to become Ready (90s timeout)..."
# ---------------------------------------------------
$KUBECTL -n $NS wait pod/ghost           --for=condition=Ready --timeout=90s || warn "ghost not ready yet"
$KUBECTL -n $NS wait pod/wordpress       --for=condition=Ready --timeout=90s || warn "wordpress not ready yet"
$KUBECTL -n $NS wait pod/listmonk        --for=condition=Ready --timeout=90s || warn "listmonk not ready yet"
$KUBECTL -n $NS wait pod/mattermost      --for=condition=Ready --timeout=90s || warn "mattermost not ready yet"
$KUBECTL -n $NS wait pod/promtail        --for=condition=Ready --timeout=90s || warn "promtail not ready yet"
$KUBECTL -n $NS wait pod/rclone-archiver --for=condition=Ready --timeout=90s || warn "rclone-archiver not ready yet"

# ---------------------------------------------------
step "9/9 — Final verification"
# ---------------------------------------------------
VERIFIED_SIZE=$(minikube ssh "cat /etc/docker/daemon.json" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin).get('log-opts',{}); print(f\"max-size={d.get('max-size','?')}, max-file={d.get('max-file','?')}\")" 2>/dev/null)
info "Docker daemon log limits: $VERIFIED_SIZE"

echo ""
info "=== Deployment complete ==="
$KUBECTL get pods -n $NS
echo ""
info "Grafana port-forward: kubectl port-forward svc/loki-grafana 3000:80 -n $NS"
info "Promtail logs:        kubectl logs pod/promtail -n $NS --tail=30"
info "Archiver logs:        kubectl logs pod/rclone-archiver -n $NS --tail=30"
