#!/bin/bash
# =============================================================================
# deploy.sh — Idempotent deploy script for the Kubernetes log pipeline
# Run from the log-rotating directory:  bash deploy.sh
# =============================================================================
set -euo pipefail

NS="log"
KUBECTL="kubectl"

info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }
step()  { echo -e "\n\033[34m▶ $*\033[0m"; }

# ---------------------------------------------------
step "1/7 — Namespace + Quota"
# ---------------------------------------------------
$KUBECTL apply -f namespace.yml
$KUBECTL -n $NS wait --for=condition=Ready pods --all --timeout=0s 2>/dev/null || true

# ---------------------------------------------------
step "2/7 — Secrets"
# ---------------------------------------------------
$KUBECTL apply -f secrets.yml
info "Secrets applied. rclone token expiry is stored in the secret — re-run if GDrive uploads fail."

# ---------------------------------------------------
step "3/7 — Grafana datasource + dashboard"
# ---------------------------------------------------
$KUBECTL apply -f grafana-datasource.yml
$KUBECTL apply -f grafana-dashboard.yml

# ---------------------------------------------------
step "4/7 — App deployments (ghost, wordpress, listmonk, mattermost)"
# ---------------------------------------------------
$KUBECTL apply -f ghost-deployment.yml
$KUBECTL apply -f wordpress-pod.yml
$KUBECTL apply -f listmonk-pod.yml
$KUBECTL apply -f mattermost-pod.yml

# ---------------------------------------------------
step "5/7 — Promtail DaemonSet"
# ---------------------------------------------------
$KUBECTL apply -f promtail-daemonset.yml

# ---------------------------------------------------
step "6/7 — Rclone Archiver DaemonSet"
# ---------------------------------------------------
$KUBECTL apply -f rclone-archiver.yml

# ---------------------------------------------------
step "7/7 — Waiting for rollout to stabilise (90s timeout)..."
# ---------------------------------------------------
$KUBECTL -n $NS rollout status deployment/ghost         --timeout=90s || warn "ghost not ready yet"
$KUBECTL -n $NS rollout status deployment/wordpress     --timeout=90s || warn "wordpress not ready yet"
$KUBECTL -n $NS rollout status deployment/listmonk      --timeout=90s || warn "listmonk not ready yet"
$KUBECTL -n $NS rollout status deployment/mattermost    --timeout=90s || warn "mattermost not ready yet"
$KUBECTL -n $NS rollout status daemonset/promtail       --timeout=90s || warn "promtail not ready yet"
$KUBECTL -n $NS rollout status daemonset/rclone-archiver --timeout=90s || warn "rclone-archiver not ready yet"

echo ""
info "=== Deployment complete ==="
$KUBECTL get all -n $NS
echo ""
info "Grafana port-forward: kubectl port-forward svc/grafana 3000:3000 -n $NS"
info "Promtail logs:        kubectl logs -l app=promtail -n $NS --tail=30"
info "Archiver logs:        kubectl logs -l app=rclone-archiver -n $NS --tail=30"
