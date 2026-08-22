#!/usr/bin/env bash
# run-ecofloc.sh — Mide consumo energético de microservicios TeaStore con EcoFloc
# Uso: ./run-ecofloc.sh <experimento> <duración_s> <intervalo_ms> <componentes> <password>
# Ejemplo: ./run-ecofloc.sh exp01 60 1000 cpu,ram,sd,nic mipassword

set -euo pipefail

# ─── Parámetros ───────────────────────────────────────────────────────────────
if [[ $# -ne 5 ]]; then
    echo "Uso: $0 <experimento> <duración_s> <intervalo_ms> <componentes> <password>"
    echo "Ejemplo: $0 exp01 60 1000 cpu,ram,sd,nic mipassword"
    exit 1
fi

EXP_NAME=$1
DURATION=$2
INTERVAL=$3
COMPONENTS_RAW=$4
SUDO_PASS=$5

# Función helper para sudo con password
sudop() {
    echo "$SUDO_PASS" | sudo -S "$@" 2>/dev/null
}

# ─── Directorio de resultados ─────────────────────────────────────────────────
RESULTS_DIR="/home/josec/results/${EXP_NAME}"
mkdir -p "$RESULTS_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NODE=$(hostname)

echo "========================================="
echo " EcoFloc — Experimento: $EXP_NAME"
echo " Nodo: $NODE"
echo " Duración: ${DURATION}s | Intervalo: ${INTERVAL}ms"
echo " Componentes: $COMPONENTS_RAW"
echo " Resultados: $RESULTS_DIR"
echo " Timestamp: $TIMESTAMP"
echo "========================================="

# ─── Parsear componentes ──────────────────────────────────────────────────────
IFS=',' read -ra COMPONENTS <<< "$COMPONENTS_RAW"

# Validar componentes
for COMP in "${COMPONENTS[@]}"; do
    if [[ ! "$COMP" =~ ^(cpu|ram|sd|nic)$ ]]; then
        echo "ERROR: componente inválido '$COMP'. Usar: cpu, ram, sd, nic"
        exit 1
    fi
done

# ─── Detectar PIDs de microservicios TeaStore ─────────────────────────────────
echo ""
echo "[ Detectando microservicios TeaStore en $NODE ]"

declare -A PID_SERVICE  # PID → nombre corto del servicio (ej: teastore-registry)

while IFS= read -r PID; do
    SVC_FULL=$(sudop cat /proc/$PID/environ | tr '\0' '\n' | grep "^HOSTNAME=" | cut -d= -f2)
    if [[ -n "$SVC_FULL" ]]; then
        SVC_SHORT=$(echo "$SVC_FULL" | grep -oP '^teastore-[a-z]+')
        PID_SERVICE[$PID]=$SVC_SHORT
        echo "  ✓ PID $PID → $SVC_SHORT"
    fi
done < <(ps aux | grep java | grep -v grep | grep "Bootstrap start" | awk '{print $2}')

if [[ ${#PID_SERVICE[@]} -eq 0 ]]; then
    echo "  ✗ No se encontraron microservicios TeaStore en este nodo"
    exit 1
fi

echo ""
echo "[ Iniciando mediciones EcoFloc ]"

# ─── Lanzar EcoFloc en paralelo ───────────────────────────────────────────────
BGPIDS=()

for PID in "${!PID_SERVICE[@]}"; do
    SVC_SHORT=${PID_SERVICE[$PID]}
    for COMP in "${COMPONENTS[@]}"; do
        echo "  → $SVC_SHORT | $COMP | PID $PID"
        sudop ecofloc --${COMP} -p $PID -i $INTERVAL -t $DURATION -f "$RESULTS_DIR/" &
        BGPIDS+=($!)
    done
done

echo ""
echo "[ Midiendo durante ${DURATION}s... ]"

for BGPID in "${BGPIDS[@]}"; do
    wait $BGPID 2>/dev/null || true
done

# ─── Renombrar CSVs: ECOFLOC_CPU_PID_4270.csv → ECOFLOC_CPU_PID_4270_TEASTORE-REGISTRY.csv ──
echo ""
echo "[ Renombrando archivos con nombre de servicio ]"

for PID in "${!PID_SERVICE[@]}"; do
    SVC_SHORT=${PID_SERVICE[$PID]}
    SVC_LABEL=$(echo "$SVC_SHORT" | tr '[:lower:]' '[:upper:]')  # teastore-registry → TEASTORE-REGISTRY

    for COMP in "${COMPONENTS[@]}"; do
        COMP_UPPER=$(echo "$COMP" | tr '[:lower:]' '[:upper:]')
        OLD_NAME="${RESULTS_DIR}/ECOFLOC_${COMP_UPPER}_PID_${PID}.csv"
        NEW_NAME="${RESULTS_DIR}/ECOFLOC_${COMP_UPPER}_PID_${PID}_${SVC_LABEL}.csv"

        if [[ -f "$OLD_NAME" ]]; then
            mv "$OLD_NAME" "$NEW_NAME"
            echo "  ✓ $(basename $NEW_NAME)"
        else
            echo "  ⚠ No encontrado: $(basename $OLD_NAME)"
        fi
    done
done

echo ""
echo "[ Resultados en $RESULTS_DIR ]"
echo ""
ls -lh "$RESULTS_DIR/"
echo ""
echo "✓ Medición completada"