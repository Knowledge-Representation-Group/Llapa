#!/usr/bin/env zsh
# collect-results.sh — Recupera resultados de EcoFloc y Scaphandre de cada worker
# Uso: ./collect-results.sh <experimento>
# Ejemplo: ./collect-results.sh exp01

set -euo pipefail

# ─── Cargar .env ──────────────────────────────────────────────────────────────
ENV_FILE="$(dirname $0)/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: no se encontró .env en $(dirname $0)"
    exit 1
fi
source "$ENV_FILE"

# ─── Parámetros ───────────────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Uso: $0 <experimento>"
    echo "Ejemplo: $0 exp01"
    exit 1
fi

EXP_NAME=$1
REMOTE_EXP_DIR="${RESULTS_REMOTE_DIR}/${EXP_NAME}"
LOCAL_EXP_DIR="${RESULTS_LOCAL_DIR}/${EXP_NAME}"

echo "========================================="
echo " Recuperando resultados: $EXP_NAME"
echo " Origen (workers): $REMOTE_EXP_DIR"
echo " Destino (local): $LOCAL_EXP_DIR"
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
    echo "ERROR: no se encontraron nodos en .env"
    exit 1
fi

# ─── Copiar resultados de cada worker ─────────────────────────────────────────
echo ""
echo "[ Recuperando archivos EcoFloc ]"

TOTAL_FILES=0

for NODE in "${(@k)NODE_IP}"; do
    IP=${NODE_IP[$NODE]}
    LOCAL_NODE_DIR="${LOCAL_EXP_DIR}/${NODE}"

    if ! sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no ${SSH_USER}@$IP \
        "test -d $REMOTE_EXP_DIR" 2>/dev/null; then
        echo "  ⚠ $NODE — sin resultados en $REMOTE_EXP_DIR, se omite"
        continue
    fi

    N_FILES=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no ${SSH_USER}@$IP \
        "ls ${REMOTE_EXP_DIR}/*.csv 2>/dev/null | wc -l")

    if [[ $N_FILES -gt 0 ]]; then
        mkdir -p "$LOCAL_NODE_DIR"
        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no \
            "${SSH_USER}@$IP:${REMOTE_EXP_DIR}/*.csv" "$LOCAL_NODE_DIR/"

        if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no ${SSH_USER}@$IP \
            "test -f ${REMOTE_EXP_DIR}/pid_map.json" 2>/dev/null; then
            sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no \
                "${SSH_USER}@$IP:${REMOTE_EXP_DIR}/pid_map.json" \
                "$LOCAL_NODE_DIR/"
        fi

        echo "  ✓ $NODE — $N_FILES CSV(s) copiado(s) → $LOCAL_NODE_DIR"
        (( TOTAL_FILES += N_FILES ))
    else
        echo "  ⚠ $NODE — sin CSVs, se omite EcoFloc"
    fi

    # ─── Copiar scaphandre JSON si existe ─────────────────────────────────────
    if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no ${SSH_USER}@$IP \
        "test -d ${REMOTE_EXP_DIR}/scaphandre" 2>/dev/null; then
        mkdir -p "${LOCAL_EXP_DIR}/scaphandre"
        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no \
            "${SSH_USER}@$IP:${REMOTE_EXP_DIR}/scaphandre/*.json" \
            "${LOCAL_EXP_DIR}/scaphandre/" 2>/dev/null && \
            echo "  ✓ $NODE — scaphandre JSON copiado → ${LOCAL_EXP_DIR}/scaphandre/" || \
            echo "  ⚠ $NODE — sin JSON de scaphandre"
    fi
done

# ─── Copiar resultados locales del control-plane ──────────────────────────────
LOCAL_NODE_NAME=$(cat /etc/hostname 2>/dev/null || echo "control-plane")
LOCAL_CONTROLPLANE_DIR="${RESULTS_REMOTE_DIR}/${EXP_NAME}"
LOCAL_NODE_DIR="${LOCAL_EXP_DIR}/${LOCAL_NODE_NAME}"

if [[ -d "$LOCAL_CONTROLPLANE_DIR" ]]; then
    N_FILES=$(ls ${LOCAL_CONTROLPLANE_DIR}/*.csv 2>/dev/null | wc -l)
    if [[ $N_FILES -gt 0 ]]; then
        mkdir -p "$LOCAL_NODE_DIR"
        cp ${LOCAL_CONTROLPLANE_DIR}/*.csv "$LOCAL_NODE_DIR/"
        if [[ -f "${LOCAL_CONTROLPLANE_DIR}/pid_map.json" ]]; then
            cp "${LOCAL_CONTROLPLANE_DIR}/pid_map.json" "$LOCAL_NODE_DIR/"
        fi
        echo "  ✓ $LOCAL_NODE_NAME (local) — $N_FILES CSV(s) copiado(s) → $LOCAL_NODE_DIR"
        (( TOTAL_FILES += N_FILES ))
    else
        echo "  ⚠ $LOCAL_NODE_NAME (local) — sin CSVs en $LOCAL_CONTROLPLANE_DIR"
    fi

    # Scaphandre local (muaddib)
    if [[ -d "${LOCAL_CONTROLPLANE_DIR}/scaphandre" ]]; then
        mkdir -p "${LOCAL_EXP_DIR}/scaphandre"
        cp ${LOCAL_CONTROLPLANE_DIR}/scaphandre/*.json \
            "${LOCAL_EXP_DIR}/scaphandre/" 2>/dev/null && \
            echo "  ✓ $LOCAL_NODE_NAME (local) — scaphandre JSON copiado" || \
            echo "  ⚠ $LOCAL_NODE_NAME (local) — sin JSON de scaphandre"
    fi
else
    echo "  ⚠ $LOCAL_NODE_NAME (local) — directorio no encontrado: $LOCAL_CONTROLPLANE_DIR"
fi

echo ""
echo "[ Archivos EcoFloc recuperados: $TOTAL_FILES ]"
echo "✓ Colección completada — $LOCAL_EXP_DIR"