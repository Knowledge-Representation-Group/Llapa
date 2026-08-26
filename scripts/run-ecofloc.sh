#!/usr/bin/env bash
# run-ecofloc.sh — Mide consumo energético de todos los procesos relevantes con EcoFloc
# Uso: ./run-ecofloc.sh <experimento> <intervalo_ms> <componentes> <password>
# Ejemplo: ./run-ecofloc.sh exp01 1000 cpu,ram,sd,nic mipassword
# Modo continuo: corre hasta que aparezca $HOME/results/<experimento>/.stop
# Re-detección: cuando aparece .redetect, escanea nuevos PIDs y los añade a la medición

set -euo pipefail

# ─── Parámetros ───────────────────────────────────────────────────────────────
if [[ $# -ne 4 ]]; then
    echo "Uso: $0 <experimento> <intervalo_ms> <componentes> <password>"
    echo "Ejemplo: $0 exp01 1000 cpu,ram,sd,nic mipassword"
    exit 1
fi

EXP_NAME=$1
INTERVAL=$2
COMPONENTS_RAW=$3
SUDO_PASS=$4

# Función helper para sudo con password
sudop() {
    if [[ -n "$SUDO_PASS" ]]; then
        echo "$SUDO_PASS" | sudo -S "$@" 2>/dev/null
    else
        sudo -n "$@" 2>/dev/null
    fi
}

# ─── Directorio de resultados y signal files ──────────────────────────────────
RESULTS_DIR="${HOME}/results/${EXP_NAME}"
STOP_FILE="$RESULTS_DIR/.stop"
REDETECT_FILE="$RESULTS_DIR/.redetect"
PID_MAP="$RESULTS_DIR/pid_map.json"
KNOWN_PIDS_FILE="$RESULTS_DIR/.known_pids"
CHILD_PIDS_FILE="$RESULTS_DIR/.child_pids"
mkdir -p "$RESULTS_DIR"

NODE=$(hostname 2>/dev/null || cat /etc/hostname || echo "unknown")
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ─── Parsear y validar componentes ───────────────────────────────────────────
IFS=',' read -ra COMPONENTS <<< "$COMPONENTS_RAW"

for COMP in "${COMPONENTS[@]}"; do
    if [[ ! "$COMP" =~ ^(cpu|ram|sd|nic)$ ]]; then
        echo "ERROR: componente inválido '$COMP'. Usar: cpu, ram, sd, nic"
        exit 1
    fi
done

# ─── Limpiar archivos de control de corridas anteriores ──────────────────────
rm -f "$STOP_FILE" "$REDETECT_FILE" "$KNOWN_PIDS_FILE" "$CHILD_PIDS_FILE"
> "$KNOWN_PIDS_FILE"
> "$CHILD_PIDS_FILE"

# ─── Función: matar todos los procesos hijos de EcoFloc ──────────────────────
kill_all_children() {
    if [[ -f "$CHILD_PIDS_FILE" ]]; then
        while IFS= read -r EPID; do
            [[ -z "$EPID" ]] && continue
            sudop kill -9 "$EPID" 2>/dev/null || true
        done < "$CHILD_PIDS_FILE"
    fi
    # Safety net
    sudop pkill -9 -f "ecofloc-cpu.out" 2>/dev/null || true
    sudop pkill -9 -f "ecofloc-ram.out" 2>/dev/null || true
    sudop pkill -9 -f "ecofloc-sd.out"  2>/dev/null || true
    sudop pkill -9 -f "ecofloc-nic.out" 2>/dev/null || true
    sudop pkill -9 -f nethogs            2>/dev/null || true
    sudop pkill -9 -f "perf stat"        2>/dev/null || true
    local REMAINING
    REMAINING=$(ps aux | grep -E 'ecofloc|nethogs|perf stat' | grep -v grep | wc -l)
}

# ─── Trap para limpiar si el script es interrumpido externamente ──────────────
trap 'trap - INT TERM; kill_all_children; exit 0' INT TERM

# ─── Función: detectar todos los procesos del nodo ───────────────────────────
detect_all_procs() {
    local TMP="$RESULTS_DIR/.pid_map_tmp"
    > "$TMP"

    # teastore — Java
    while IFS= read -r PID; do
        SVC_FULL=$(sudop cat /proc/$PID/environ 2>/dev/null | tr '\0' '\n' | grep "^HOSTNAME=" | cut -d= -f2 || true)
        if [[ -n "$SVC_FULL" ]]; then
            SVC_SHORT=$(echo "$SVC_FULL" | grep -oP '^teastore-[a-z]+' || true)
            if [[ -n "$SVC_SHORT" ]]; then
                echo "$PID|java|teastore|$SVC_SHORT" >> "$TMP"
            fi
        fi
    done < <(ps aux | grep java | grep -v grep | grep "Bootstrap start" | awk '{print $2}' || true)

    # teastore — mysqld
    while IFS= read -r PID; do
        echo "$PID|mysqld|teastore|teastore-db" >> "$TMP"
    done < <(ps aux | grep -w mysqld | grep -v grep | awk '{print $2}' || true)

    # k8s
    _detect_k8s_proc() {
        local PROC_NAME=$1 GREP_PATTERN=$2
        while IFS= read -r PID; do
            [[ -n "$PID" ]] && ! grep -q "^$PID|" "$TMP" 2>/dev/null && \
                echo "$PID|$PROC_NAME|k8s|$PROC_NAME" >> "$TMP"
        done < <(ps aux | grep "$GREP_PATTERN" | grep -v grep | awk '{print $2}' || true)
    }
    _detect_k8s_proc "kubelet"                 "/usr/bin/kubelet"
    _detect_k8s_proc "containerd"              "/usr/bin/containerd$"
    _detect_k8s_proc "containerd-shim"         "containerd-shim"
    _detect_k8s_proc "kube-proxy"              "/usr/local/bin/kube-proxy"
    _detect_k8s_proc "flanneld"                "/opt/bin/flanneld"
    _detect_k8s_proc "kube-apiserver"          "kube-apiserver"
    _detect_k8s_proc "kube-controller-manager" "kube-controller-manager"
    _detect_k8s_proc "kube-scheduler"          "kube-scheduler"
    _detect_k8s_proc "etcd"                    "/usr/local/bin/etcd\|/bin/etcd\|[[:space:]]etcd[[:space:]]"
    _detect_k8s_proc "coredns"                 "/coredns"

    echo "$TMP"
}

# ─── Función: actualizar pid_map.json fusionando entradas ────────────────────
update_pid_map() {
    local TMP=$1
    python3 - "$TMP" "$PID_MAP" "$NODE" <<'PYEOF'
import json, sys, os

tmp_file = sys.argv[1]
out_file = sys.argv[2]
node     = sys.argv[3]

existing = {}
if os.path.exists(out_file):
    with open(out_file) as f:
        existing = json.load(f)

new_entries = {}
with open(tmp_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) == 4:
            pid, name, category, service = parts
            new_entries[pid] = {"name": name, "category": category, "service": service, "node": node}

added = 0
for pid, info in new_entries.items():
    if pid not in existing:
        existing[pid] = info
        added += 1

with open(out_file, "w") as f:
    json.dump(existing, f, indent=2)
PYEOF
}

# ─── Función: lanzar EcoFloc para PIDs nuevos y registrar PGIDs reales ───────
launch_ecofloc_for_new() {
    local TMP=$1
    local NEW_COUNT=0

    while IFS='|' read -r PID NAME CATEGORY SERVICE; do
        if grep -q "^$PID$" "$KNOWN_PIDS_FILE" 2>/dev/null; then
            continue
        fi

        echo "$PID" >> "$KNOWN_PIDS_FILE"
        (( NEW_COUNT++ )) || true

        for COMP in "${COMPONENTS[@]}"; do
            sudop setsid ecofloc --${COMP} -p $PID -i $INTERVAL -t -1 -f "$RESULTS_DIR/" \
                </dev/null &>/dev/null &
        done

        # Esperar que los procesos arranquen y capturar sus PGIDs reales
        # Los procesos ecofloc lanzados con setsid tienen PGID = PID propio
        sleep 0.5
        for COMP in "${COMPONENTS[@]}"; do
            EPID=$(ps -eo pid,cmd 2>/dev/null \
                | grep "ecofloc-${COMP}.out" \
                | grep "\-p $PID " \
                | grep -v grep \
                | awk '{print $1}' | head -1 | tr -d ' ' || true)
            [[ -n "$EPID" ]] && echo "$EPID" >> "$CHILD_PIDS_FILE"
        done
    done < "$TMP"
}

# ─── Detección inicial ────────────────────────────────────────────────────────
TMP=$(detect_all_procs)
TOTAL=$(wc -l < "$TMP")

if [[ "$TOTAL" -eq 0 ]]; then
    echo "  ✗ No se encontraron procesos a medir en este nodo"
    rm -f "$TMP"
    exit 1
fi

echo "  Total procesos detectados: $TOTAL"
update_pid_map "$TMP"

launch_ecofloc_for_new "$TMP"
rm -f "$TMP"


# ─── Loop principal: esperar .stop o .redetect ───────────────────────────────
while true; do
    if [[ -f "$STOP_FILE" ]]; then
        trap - INT TERM
        kill_all_children
        sleep 2
        break
    fi

    if [[ -f "$REDETECT_FILE" ]]; then
        rm -f "$REDETECT_FILE"
        TMP=$(detect_all_procs)
        update_pid_map "$TMP"
        launch_ecofloc_for_new "$TMP"
        rm -f "$TMP"
    fi

    sleep 2
done

# ─── Renombrar CSVs usando pid_map.json ──────────────────────────────────────

python3 - "$PID_MAP" "$RESULTS_DIR" <<'PYEOF'
import json, os, sys

pid_map     = json.load(open(sys.argv[1]))
results_dir = sys.argv[2]

for pid, info in pid_map.items():
    service_label = info["service"].upper()
    for f in os.listdir(results_dir):
        if f.startswith("ECOFLOC_") and f"_PID_{pid}." in f and f"_PID_{pid}_" not in f:
            old_path = os.path.join(results_dir, f)
            base     = f.rsplit(".", 1)[0]
            ext      = f.rsplit(".", 1)[1]
            new_name = f"{base}_{service_label}.{ext}"
            new_path = os.path.join(results_dir, new_name)
            os.rename(old_path, new_path)
PYEOF