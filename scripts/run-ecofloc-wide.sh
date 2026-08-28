#!/usr/bin/env zsh
# run-ecofloc-wide.sh — Lanza run-ecofloc.sh en todos los workers con pods TeaStore
# Uso: ./run-ecofloc-wide.sh <experimento> <intervalo_ms> <componentes>
# Ejemplo: ./run-ecofloc-wide.sh exp01 1000 cpu,ram,sd,nic
# Modo continuo: corre hasta que el orquestador envíe señal de parada (.stop)

set -euo pipefail

# ─── Cargar .env ──────────────────────────────────────────────────────────────
ENV_FILE="${0:A:h}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: no se encontró .env en ${0:A:h}"
    exit 1
fi
source "$ENV_FILE"

# ─── Parámetros ───────────────────────────────────────────────────────────────
if [[ $# -ne 3 ]]; then
    echo "Uso: $0 <experimento> <intervalo_ms> <componentes>"
    echo "Ejemplo: $0 exp01 1000 cpu,ram,sd,nic"
    exit 1
fi

EXP_NAME=$1
INTERVAL=$2
COMPONENTS=$3

SCRIPT_REMOTE="${REMOTE_SCRIPT_DIR}/run-ecofloc.sh"

echo "========================================="
echo " EcoFloc Wide — Experimento: $EXP_NAME"
echo " Intervalo: ${INTERVAL}ms | Modo: continuo"
echo " Componentes: $COMPONENTS"
echo "========================================="

# ─── Construir mapeo nombre→IP desde .env ─────────────────────────────────────
declare -A NODE_IP

i=1
while true; do
    NAME_VAR="NODE_${i}_NAME"
    IP_VAR="NODE_${i}_IP"
    NAME="${(P)NAME_VAR:-}"
    IP="${(P)IP_VAR:-}"
    [[ -z "$NAME" || -z "$IP" ]] && break
    NODE_IP[$NAME]=$IP
    (( i++ ))
done

if [[ ${#NODE_IP[@]} -eq 0 ]]; then
    echo "ERROR: no se encontraron nodos en .env (NODE_1_NAME, NODE_1_IP, ...)"
    exit 1
fi

echo ""
echo "[ Nodos registrados en .env: ${#NODE_IP[@]} ]"
for NODE in "${(@k)NODE_IP}"; do
    echo "  · $NODE (${NODE_IP[$NODE]})"
done

# ─── Verificar que run-ecofloc.sh existe en cada worker ──────────────────────
echo ""
echo "[ Verificando run-ecofloc.sh en workers ]"

typeset -a VALID_WORKERS

for NODE in "${(@k)NODE_IP}"; do
    IP=${NODE_IP[$NODE]}
    if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no ${SSH_USER}@$IP "test -f $SCRIPT_REMOTE"; then
        VALID_WORKERS+=($NODE)
        echo "  ✓ $NODE — script encontrado"
    else
        echo "  ✗ $NODE — $SCRIPT_REMOTE no encontrado, se omite"
    fi
done

if [[ ${#VALID_WORKERS[@]} -eq 0 ]]; then
    echo ""
    echo "ERROR: ningún worker tiene $SCRIPT_REMOTE — no se puede continuar"
    exit 1
fi

# ─── Lanzar run-ecofloc.sh en paralelo en cada worker ────────────────────────
echo ""
echo "[ Lanzando EcoFloc en ${#VALID_WORKERS[@]} worker(s) en paralelo ]"

typeset -a BGPIDS

for NODE in "${VALID_WORKERS[@]}"; do
    IP=${NODE_IP[$NODE]}
    echo "  → SSH $NODE ($IP)"
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no ${SSH_USER}@$IP \
        "bash $SCRIPT_REMOTE $EXP_NAME $INTERVAL $COMPONENTS $SUDO_PASS" &
    BGPIDS+=($!)
done

echo ""
echo "[ EcoFloc corriendo en modo continuo en ${#VALID_WORKERS[@]} worker(s) ]"
echo "[ Esperando señal de parada desde el orquestador... ]"

# ─── Lanzar también localmente (control-plane) ────────────────────────────────
LOCAL_SCRIPT="${0:A:h}/run-ecofloc.sh"
if [[ -f "$LOCAL_SCRIPT" ]]; then
    echo "  → LOCAL (control-plane)"
    bash "$LOCAL_SCRIPT" "$EXP_NAME" "$INTERVAL" "$COMPONENTS" "" &
    BGPIDS+=($!)
else
    echo "  ⚠ run-ecofloc.sh no encontrado localmente — control-plane no se medirá"
fi

# ─── Esperar a que todos los workers terminen (señal llegará vía .stop) ───────
for BGPID in "${BGPIDS[@]}"; do
    wait $BGPID 2>/dev/null || true
done

echo ""
echo "✓ EcoFloc completado en todos los workers"
echo "  Resultados en ${RESULTS_REMOTE_DIR}/$EXP_NAME/ en cada worker"