#!/usr/bin/env bash
# run-scaphandre.sh — Mide consumo energético con Scaphandre en modo JSON
# Uso: ./run-scaphandre.sh <experimento> <intervalo_s> <password>
# Ejemplo: ./run-scaphandre.sh exp01 5 mipassword
# Modo continuo: corre hasta que aparezca $HOME/results/<experimento>/.stop

set -euo pipefail

# ─── Parámetros ───────────────────────────────────────────────────────────────
if [[ $# -ne 3 ]]; then
    echo "Uso: $0 <experimento> <intervalo_s> <password>"
    echo "Ejemplo: $0 exp01 5 mipassword"
    exit 1
fi

EXP_NAME=$1
INTERVAL=$2       # en segundos (scaphandre usa segundos, no ms)
SUDO_PASS=$3

# Función helper para sudo con password
sudop() {
    if [[ -n "$SUDO_PASS" ]]; then
        echo "$SUDO_PASS" | sudo -S "$@" 2>/dev/null
    else
        sudo -n "$@" 2>/dev/null
    fi
}

# ─── Directorios y archivos de control ───────────────────────────────────────
RESULTS_DIR="${HOME}/results/${EXP_NAME}"
SCAPH_DIR="$RESULTS_DIR/scaphandre"
STOP_FILE="$RESULTS_DIR/.stop"
SCAPH_OUT="$SCAPH_DIR/$(cat /etc/hostname 2>/dev/null || echo unknown).json"
SCAPH_PID_FILE="$RESULTS_DIR/.scaphandre_pid"
mkdir -p "$SCAPH_DIR"

NODE=$(cat /etc/hostname 2>/dev/null || echo "unknown")

# ─── Regex de procesos a capturar ────────────────────────────────────────────
# TeaStore: java (tomcat), mysqld
# k8s: kubelet, containerd, kube-proxy, flanneld, coredns, etcd, kube-apiserver
PROCESS_REGEX="java|mysqld|kubelet|containerd|kube-proxy|flanneld|coredns|etcd|kube-apiserver|kube-controller|kube-scheduler"

# ─── Función: matar scaphandre ───────────────────────────────────────────────
kill_scaphandre() {
    if [[ -f "$SCAPH_PID_FILE" ]]; then
        local SPID
        SPID=$(cat "$SCAPH_PID_FILE")
        sudop kill -9 "$SPID" 2>/dev/null || true
        rm -f "$SCAPH_PID_FILE"
    fi
    sudop pkill -9 -f "scaphandre json" 2>/dev/null || true
}

# ─── Trap para limpiar si el script es interrumpido externamente ──────────────
trap 'trap - INT TERM; kill_scaphandre; exit 0' INT TERM

# ─── Lanzar scaphandre en background ─────────────────────────────────────────
echo "  [scaphandre] Nodo: $NODE | Intervalo: ${INTERVAL}s"
echo "  [scaphandre] Output: $SCAPH_OUT"
echo "  [scaphandre] Regex: $PROCESS_REGEX"

# --max-top-consumers 50: captura hasta 50 procesos por snapshot
# --process-regex: filtra solo procesos relevantes
# -f: escribe a archivo JSON (scaphandre append automáticamente snapshots)
sudop setsid /opt/scaphandre json \
    -s "$INTERVAL" \
    --max-top-consumers 50 \
    --process-regex "$PROCESS_REGEX" \
    -f "$SCAPH_OUT" \
    </dev/null &>/dev/null &

sleep 0.5

# Capturar PID real del proceso scaphandre
SCAPH_PID=$(ps -eo pid,cmd 2>/dev/null \
    | grep "scaphandre json" \
    | grep -v grep \
    | awk '{print $1}' | head -1 | tr -d ' ' || true)

if [[ -z "$SCAPH_PID" ]]; then
    echo "  ✗ ERROR: scaphandre no arrancó"
    exit 1
fi

echo "$SCAPH_PID" > "$SCAPH_PID_FILE"
echo "  [scaphandre] PID: $SCAPH_PID — midiendo..."

# ─── Loop principal: esperar .stop ───────────────────────────────────────────
while true; do
    if [[ -f "$STOP_FILE" ]]; then
        trap - INT TERM
        kill_scaphandre
        sleep 1
        break
    fi
    sleep 2
done

# ─── Verificar output ─────────────────────────────────────────────────────────
if [[ -f "$SCAPH_OUT" ]]; then
    LINES=$(wc -c < "$SCAPH_OUT")
    echo "  [scaphandre] Captura finalizada — ${LINES} bytes en $SCAPH_OUT"
else
    echo "  ✗ [scaphandre] ERROR: no se generó output en $SCAPH_OUT"
fi
