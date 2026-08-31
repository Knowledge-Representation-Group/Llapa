#!/usr/bin/env zsh
# run-scaphandre-wide.sh — Lanza run-scaphandre.sh en todos los workers + muaddib
# Uso: ./run-scaphandre-wide.sh <experimento> <intervalo_s>
# Ejemplo: ./run-scaphandre-wide.sh exp01 5

set -euo pipefail

# ─── Cargar .env ──────────────────────────────────────────────────────────────
ENV_FILE="${0:A:h}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: no se encontró .env en ${0:A:h}"
    exit 1
fi
source "$ENV_FILE"

# ─── Parámetros ───────────────────────────────────────────────────────────────
if [[ $# -ne 2 ]]; then
    echo "Uso: $0 <experimento> <intervalo_s>"
    echo "Ejemplo: $0 exp01 5"
    exit 1
fi

EXP_NAME=$1
INTERVAL=$2
SCRIPT_REMOTE="${REMOTE_SCRIPT_DIR}/run-scaphandre.sh"

echo "========================================="
echo " Scaphandre Wide — Experimento: $EXP_NAME"
echo " Intervalo: ${INTERVAL}s | Modo: continuo"
echo "========================================="

# ─── Lanzar en workers vía SSH ───────────────────────────────────────────────
NODE_IDX=1
while true; do
    NODE_NAME_VAR="NODE_${NODE_IDX}_NAME"
    NODE_IP_VAR="NODE_${NODE_IDX}_IP"

    NODE_NAME="${(P)NODE_NAME_VAR:-}"
    NODE_IP="${(P)NODE_IP_VAR:-}"

    [[ -z "$NODE_NAME" || -z "$NODE_IP" ]] && break

    echo "  → Lanzando scaphandre en $NODE_NAME ($NODE_IP)..."
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no \
        "${SSH_USER}@${NODE_IP}" \
        "bash $SCRIPT_REMOTE $EXP_NAME $INTERVAL '$SUDO_PASS'" \
        </dev/null &>/dev/null &

    (( NODE_IDX++ ))
done

if [[ $NODE_IDX -eq 1 ]]; then
    echo "ERROR: no se encontraron nodos en .env (NODE_1_NAME, NODE_1_IP, ...)"
    exit 1
fi

# ─── Lanzar localmente en muaddib ────────────────────────────────────────────
SCRIPT_LOCAL="${0:A:h}/run-scaphandre.sh"
echo "  → Lanzando scaphandre en muaddib (local)..."
bash "$SCRIPT_LOCAL" "$EXP_NAME" "$INTERVAL" "$SUDO_PASS" \
    </dev/null &>/dev/null &

echo "  ✓ Scaphandre lanzado en $((NODE_IDX)) nodos"
echo "========================================="