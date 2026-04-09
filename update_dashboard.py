import yaml, json

with open('grafana-dashboard.yml', 'r') as f:
    config = yaml.safe_load(f)

dashboard = json.loads(config['data']['k8s-log-explorer.json'])
dashboard['refresh'] = '10s'
dashboard['time'] = {'from': 'now-1h', 'to': 'now'}

# ── Strip ALL existing prometheus panels (ids 4-12) and any duplicates ───────
PROMETHEUS_IDS = {4, 5, 6, 7, 8, 9, 10, 11, 12}
original_panels = [p for p in dashboard['panels'] if p.get('id') not in PROMETHEUS_IDS]

for panel in original_panels:
    panel['gridPos']['y'] = (panel['gridPos']['y'] % 1000) + 24

# ── New panels ────────────────────────────────────────────────────────────────
panels = [
    # ── ROW 1: Memory + Restarts (y=0) ───────────────────────────────────────
    {
        "id": 4,
        "title": "Pod Memory Usage (RAM)",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 16, "x": 0, "y": 0},
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "targets": [{
            "expr": "sum(container_memory_working_set_bytes{namespace=\"$namespace\", pod=~\"$pod\"}) by (pod) / 1024 / 1024",
            "legendFormat": "{{pod}} (MB)"
        }],
        "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["last", "max"]}},
        "fieldConfig": {
            "defaults": {
                "unit": "decmbytes",
                "custom": {"lineWidth": 2, "fillOpacity": 10}
            }
        }
    },
    {
        "id": 5,
        "title": "Pod Restarts",
        "type": "stat",
        "gridPos": {"h": 8, "w": 8, "x": 16, "y": 0},
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "targets": [{
            "expr": "sum(kube_pod_container_status_restarts_total{namespace=\"$namespace\", pod=~\"$pod\"}) by (pod)",
            "legendFormat": "{{pod}}"
        }],
        "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "auto"}
    },

    # ── ROW 2: CPU + Pod Status (y=8) ────────────────────────────────────────
    {
        "id": 7,
        "title": "Pod CPU Usage",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 16, "x": 0, "y": 8},
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "targets": [{
            "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"$namespace\", pod=~\"$pod\"}[5m])) by (pod) * 1000",
            "legendFormat": "{{pod}} (m)"
        }],
        "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["last", "max"]}},
        "fieldConfig": {
            "defaults": {
                "unit": "short",
                "custom": {"lineWidth": 2, "fillOpacity": 10}
            }
        }
    },
    {
        "id": 8,
        "title": "Pod Status",
        "type": "table",
        "gridPos": {"h": 8, "w": 8, "x": 16, "y": 8},
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "targets": [{
            "expr": "kube_pod_status_phase{namespace=\"$namespace\"} == 1",
            "instant": True,
            "format": "table",
            "legendFormat": ""
        }],
        "fieldConfig": {
            "defaults": {"custom": {"displayMode": "auto"}},
            "overrides": [
                {"matcher": {"id": "byName", "options": "Time"},      "properties": [{"id": "custom.hidden", "value": True}]},
                {"matcher": {"id": "byName", "options": "Value"},     "properties": [{"id": "custom.hidden", "value": True}]},
                {"matcher": {"id": "byName", "options": "__name__"},  "properties": [{"id": "custom.hidden", "value": True}]},
                {"matcher": {"id": "byName", "options": "instance"},  "properties": [{"id": "custom.hidden", "value": True}]},
                {"matcher": {"id": "byName", "options": "job"},       "properties": [{"id": "custom.hidden", "value": True}]},
                {"matcher": {"id": "byName", "options": "namespace"}, "properties": [{"id": "custom.hidden", "value": True}]},
                {"matcher": {"id": "byName", "options": "uid"},       "properties": [{"id": "custom.hidden", "value": True}]},
                {"matcher": {"id": "byName", "options": "phase"}, "properties": [
                    {"id": "custom.displayMode", "value": "color-background"},
                    {"id": "mappings", "value": [
                        {"type": "value", "options": {
                            "Running":   {"text": "Running",   "color": "green",  "index": 0},
                            "Pending":   {"text": "Pending",   "color": "yellow", "index": 1},
                            "Failed":    {"text": "Failed",    "color": "red",    "index": 2},
                            "Succeeded": {"text": "Succeeded", "color": "blue",   "index": 3},
                            "Unknown":   {"text": "Unknown",   "color": "orange", "index": 4}
                        }}
                    ]}
                ]},
                {"matcher": {"id": "byName", "options": "pod"}, "properties": [
                    {"id": "custom.width", "value": 200}
                ]}
            ]
        },
        "options": {
            "sortBy": [{"displayName": "pod", "desc": False}],
            "footer": {"show": False}
        },
        "links": [{
            "title": "Filter by pod",
            "url": "?var-pod=${__data.fields.pod}",
            "targetBlank": False
        }]
    },

    # ── ROW 3: Disk I/O (y=16) ───────────────────────────────────────────────
    {
        "id": 12,
        "title": "Disk I/O per Pod",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 24, "x": 0, "y": 16},
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "targets": [
            {
                "expr": "sum(rate(container_fs_reads_bytes_total{namespace=\"$namespace\", pod=~\"$pod\"}[5m])) by (pod)",
                "legendFormat": "{{pod}} read"
            },
            {
                "expr": "sum(rate(container_fs_writes_bytes_total{namespace=\"$namespace\", pod=~\"$pod\"}[5m])) by (pod)",
                "legendFormat": "{{pod}} write"
            }
        ],
        "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["last", "max"]}},
        "fieldConfig": {
            "defaults": {
                "unit": "Bps",
                "custom": {"lineWidth": 2, "fillOpacity": 10}
            }
        }
    },

    # ── ROW 4: Memory Requests (Pie Chart) ──────────────────────────────────
    {
        "id": 13,
        "title": "Top 10 Pods by Memory Requests",
        "type": "piechart",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 24},
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "targets": [{
            "expr": "topk(10, sum by (pod) (kube_pod_container_resource_requests{resource=\"memory\"}))",
            "legendFormat": "{{pod}}"
        }],
        "options": {
            "legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
            "pieType": "pie",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "tooltip": {"mode": "single", "sort": "none"}
        },
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "palette-classic"},
                "custom": {"hideFrom": {"legend": False, "tooltip": False, "viz": False}}
            }
        }
    },
]

dashboard['panels'] = panels + original_panels

# ── Template variables ────────────────────────────────────────────────────────
existing_names = [t['name'] for t in dashboard['templating']['list']]

# 1. Prometheus datasource variable
if 'DS_PROMETHEUS' not in existing_names:
    ds_prom = {
        "name": "DS_PROMETHEUS",
        "type": "datasource",
        "query": "prometheus",
        "current": {"text": "Prometheus", "value": "prometheus"},
        "hide": 2
    }
    dashboard['templating']['list'].insert(1, ds_prom)
    existing_names.append('DS_PROMETHEUS')

# 2. Dynamic pod selector — always replace to ensure clean state
dashboard['templating']['list'] = [
    t for t in dashboard['templating']['list'] if t['name'] != 'pod'
]
pod_var = {
    "name": "pod",
    "label": "Pod",
    "type": "query",
    "datasource": {"type": "prometheus", "uid": "prometheus"},
    "definition": "label_values(kube_pod_info{namespace=\"$namespace\"}, pod)",
    "query": {
        "query": "label_values(kube_pod_info{namespace=\"$namespace\"}, pod)",
        "refId": "StandardVariableQuery"
    },
    "refresh": 2,
    "sort": 1,
    "multi": True,
    "includeAll": True,
    "allValue": ".*",
    "current": {"text": "All", "value": "$__all"},
    "hide": 0
}
ns_index = next((i for i, t in enumerate(dashboard['templating']['list']) if t['name'] == 'namespace'), 0)
dashboard['templating']['list'].insert(ns_index + 1, pod_var)

# ── Write back ────────────────────────────────────────────────────────────────
config['data']['k8s-log-explorer.json'] = json.dumps(dashboard, indent=2) + '\n'

with open('grafana-dashboard.yml', 'w') as f:
    yaml.dump(config, f, sort_keys=False)

print("Dashboard updated successfully.")
print(f"Total panels: {len(dashboard['panels'])}")
print(f"Variables: {[t['name'] for t in dashboard['templating']['list']]}")