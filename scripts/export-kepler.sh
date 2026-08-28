#!/usr/bin/env bash
# export-kepler.sh
# Exporta métricas Kepler (CPU package + DRAM) a CSV para un experimento dado.
# Uso: ./export-kepler.sh <exp_name> <start> <end>
#
# Fechas en hora LOCAL del sistema:
#   "2026-08-26 12:20:00"
#   "2026-08-26T12:20:00"
#   "2026-08-26T17:00:00Z"  ← ya en UTC, se usa directo

set -euo pipefail

EXP_NAME="${1:-}"
START_ARG="${2:-}"
END_ARG="${3:-}"
STEP="5s"  # fijo — igual al scrape interval del ServiceMonitor (kepler-servicemonitor.yaml)

if [[ -z "$EXP_NAME" || -z "$START_ARG" || -z "$END_ARG" ]]; then
    echo "Uso: $0 <exp_name> <start> <end>"
    echo "     $0 exp-low-01 '2026-08-26 12:20:00' '2026-08-26 13:00:00'"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] No se encontró .env en $ENV_FILE"; exit 1
fi
set -a; source "$ENV_FILE"; set +a

to_unix() {
    local raw="${1//T/ }"
    raw="${raw%Z}"
    if [[ "$1" == *Z ]]; then
        date -u -d "$raw" +%s
    else
        date -d "$raw" +%s
    fi
}

START_UNIX=$(to_unix "$START_ARG")
END_UNIX=$(to_unix "$END_ARG")
START_UTC=$(date -u -d "@${START_UNIX}" +"%Y-%m-%dT%H:%M:%SZ")
END_UTC=$(date -u -d "@${END_UNIX}" +"%Y-%m-%dT%H:%M:%SZ")

PROM_URL="${PROM_URL:-http://localhost:9090}"
OUT_DIR="${RESULTS_LOCAL_DIR}/${EXP_NAME}/kepler"
mkdir -p "$OUT_DIR"

# Script Python para convertir JSON → CSV (archivo temporal)
PY_CONVERTER=$(mktemp /tmp/kepler_conv_XXXXXX.py)
cat > "$PY_CONVERTER" << 'PYEOF'
import json, sys, csv
from datetime import datetime

out_file   = sys.argv[1]
label_cols = sys.argv[2].split(',')
json_file  = sys.argv[3]

with open(json_file) as f:
    data = json.load(f)

results = data['data']['result']

with open(out_file, 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['timestamp_unix', 'timestamp_local'] + label_cols + ['value'])
    for series in results:
        metric     = series['metric']
        label_vals = [metric.get(col, '') for col in label_cols]
        for ts, val in series['values']:
            ts_f   = float(ts)
            ts_loc = datetime.fromtimestamp(ts_f).strftime('%Y-%m-%d %H:%M:%S')
            writer.writerow([ts_f, ts_loc] + label_vals + [val])

print(f"  → {out_file.split('/')[-1]}  ({len(results)} series)")
PYEOF

TMPJSON=$(mktemp /tmp/kepler_resp_XXXXXX.json)
trap 'rm -f "$PY_CONVERTER" "$TMPJSON"' EXIT

echo "═══════════════════════════════════════════════════"
echo "  export-kepler.sh"
echo "  Experimento : $EXP_NAME"
echo "  Inicio      : $START_ARG  →  $START_UTC (UTC)"
echo "  Fin         : $END_ARG  →  $END_UTC (UTC)"
echo "  Step        : $STEP"
echo "  Prometheus  : $PROM_URL"
echo "  Output      : $OUT_DIR"
echo "═══════════════════════════════════════════════════"

if ! curl -sf "${PROM_URL}/api/v1/query" --data-urlencode 'query=up' > /dev/null 2>&1; then
    echo "[ERROR] Prometheus no accesible en ${PROM_URL}"
    echo "        Ejecuta: kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &"
    exit 1
fi
echo "[OK] Prometheus accesible"

query_to_csv() {
    local query="$1"
    local out_file="$2"
    local label_cols="$3"

    curl -sf "${PROM_URL}/api/v1/query_range" \
        --data-urlencode "query=${query}" \
        --data-urlencode "start=${START_UNIX}" \
        --data-urlencode "end=${END_UNIX}" \
        --data-urlencode "step=${STEP}" \
        -o "$TMPJSON"

    local n_series
    n_series=$(python3 -c \
        "import json; d=json.load(open('$TMPJSON')); print(len(d['data']['result']))" 2>/dev/null || echo 0)

    if [[ "$n_series" -eq 0 ]]; then
        echo "  [WARN] 0 series — $(echo "$query" | cut -c1-70)"
        return 0
    fi

    python3 "$PY_CONVERTER" "$out_file" "$label_cols" "$TMPJSON"
}

NAMESPACES=("teastore" "kube-system" "kube-flannel" "kepler")
ZONES=("package" "dram")

echo ""
echo "[1/3] kepler_pod_cpu_joules_total..."
for ns in "${NAMESPACES[@]}"; do
    for zone in "${ZONES[@]}"; do
        query_to_csv \
            "kepler_pod_cpu_joules_total{pod_namespace=\"${ns}\", zone=\"${zone}\"}" \
            "${OUT_DIR}/pod_cpu_joules_${ns}_${zone}.csv" \
            "pod_name,node_name,pod_namespace,zone"
    done
done

echo ""
echo "[2/3] kepler_pod_cpu_watts..."
for ns in "${NAMESPACES[@]}"; do
    for zone in "${ZONES[@]}"; do
        query_to_csv \
            "kepler_pod_cpu_watts{pod_namespace=\"${ns}\", zone=\"${zone}\"}" \
            "${OUT_DIR}/pod_cpu_watts_${ns}_${zone}.csv" \
            "pod_name,node_name,pod_namespace,zone"
    done
done

echo ""
echo "[3/3] Métricas de nodo..."
for zone in "package" "dram" "core" "psys"; do
    query_to_csv \
        "kepler_node_cpu_active_watts{zone=\"${zone}\"}" \
        "${OUT_DIR}/node_active_watts_${zone}.csv" \
        "node_name,zone"
    query_to_csv \
        "kepler_node_cpu_active_joules_total{zone=\"${zone}\"}" \
        "${OUT_DIR}/node_active_joules_${zone}.csv" \
        "node_name,zone"
done
query_to_csv \
    "kepler_node_cpu_idle_watts{zone=\"package\"}" \
    "${OUT_DIR}/node_idle_watts_package.csv" \
    "node_name,zone"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Exportación completada"
N_FILES=$(ls "${OUT_DIR}"/*.csv 2>/dev/null | wc -l || echo 0)
echo "  Archivos : $N_FILES CSVs en $OUT_DIR"
echo "═══════════════════════════════════════════════════"