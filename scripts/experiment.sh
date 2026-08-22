#!/usr/bin/env zsh
# experiment.sh — Lanza run-ecofloc.sh en todos los workers con pods TeaStore
# Uso: ./experiment.sh <experimento> <duración_s> <intervalo_ms> <componentes>
# Ejemplo: ./experiment.sh exp01 60 1000 cpu,ram,sd,nic

set -euo pipefail

# ─── Cargar .env ──────────────────────────────────────────────────────────────
ENV_FILE="$(dirname $0)/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: no se encontró .env en $(dirname $0)"
    exit 1
fi
source "$ENV_FILE"

# ─── Parámetros ───────────────────────────────────────────────────────────────
if [[ $# -ne 4 ]]; then
    echo "Uso: $0 <experimento> <duración_s> <intervalo_ms> <componentes>"
    exit 1
fi

EXP_NAME=$1
DURATION=$2
INTERVAL=$3
COMPONENTS=$4

SCRIPT_REMOTE="/home/josec/utils-scripts/run-ecofloc.sh"

echo "========================================="
echo " Experimento: $EXP_NAME"
echo " Duración: ${DURATION}s | Intervalo: ${INTERVAL}ms"
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

# ─── Detectar workers con pods TeaStore activos ───────────────────────────────
echo ""
echo "[ Detectando workers con pods TeaStore ]"

typeset -a ACTIVE_WORKERS

while IFS= read -r NODE; do
    if [[ -n "${NODE_IP[$NODE]+_}" ]]; then
        ACTIVE_WORKERS+=($NODE)
        echo "  ✓ $NODE (${NODE_IP[$NODE]})"
    fi
done < <(kubectl get pods -n teastore -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)

if [[ ${#ACTIVE_WORKERS[@]} -eq 0 ]]; then
    echo "  ✗ No hay workers con pods TeaStore activos"
    exit 1
fi

# ─── Verificar que run-ecofloc.sh existe en cada worker ──────────────────────
echo ""
echo "[ Verificando run-ecofloc.sh en workers ]"

typeset -a VALID_WORKERS

for NODE in "${ACTIVE_WORKERS[@]}"; do
    IP=${NODE_IP[$NODE]}
    if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no josec@$IP "test -f $SCRIPT_REMOTE"; then
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
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no josec@$IP \
        "bash $SCRIPT_REMOTE $EXP_NAME $DURATION $INTERVAL $COMPONENTS $SUDO_PASS" &
    BGPIDS+=($!)
done

echo ""
echo "[ Midiendo durante ${DURATION}s... esperando workers ]"

for BGPID in "${BGPIDS[@]}"; do
    wait $BGPID 2>/dev/null || true
done

echo ""
echo "✓ Experimento $EXP_NAME completado"
echo "  Resultados en /home/josec/results/$EXP_NAME/ en cada worker"
