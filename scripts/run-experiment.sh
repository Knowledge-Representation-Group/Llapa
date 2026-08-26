#!/usr/bin/env zsh
# run-experiment.sh — Orquestador principal del experimento TeaStore + EcoFloc
# Uso: ./run-experiment.sh <experimento> <intervalo_ms> <componentes> [opciones]
# Ejemplo: ./run-experiment.sh exp01 1000 cpu,ram,sd,nic --profile low

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ENV_FILE="$SCRIPT_DIR/.env"

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo "${CYAN}[EXP]${NC} $*" }
success() { echo "${GREEN}[EXP]${NC} $*" }
warn()    { echo "${YELLOW}[EXP]${NC} $*" }
error()   { echo "${RED}[EXP] ERROR:${NC} $*" >&2; exit 1 }
phase()   {
    echo ""
    echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "${BLUE}  FASE: $*${NC}"
    echo "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─── Cargar .env ──────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || error "No se encontró .env en $SCRIPT_DIR"
set -a; source "$ENV_FILE"; set +a

# ─── Uso ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Uso: $0 <experimento> <intervalo_ms> <componentes> [opciones]

Argumentos obligatorios:
  <experimento>           Nombre del experimento
  <intervalo_ms>          Intervalo de muestreo EcoFloc en ms (ej: 1000)
  <componentes>           Componentes EcoFloc: cpu,ram,sd,nic

Parámetros BD (teastore-gendb):
  --categories <n>        Categorías (default: 5)
  --products <n>          Productos por categoría (default: 100)
  --users <n>             Usuarios (default: 100)
  --orders <n>            Órdenes por usuario (default: 5)

Perfil de carga LIMBO (elige uno):
  --profile <nombre>      Perfil predefinido: low | med | high | <nombre>.csv
  --max-rps <n>           Máximo req/s (perfil dinámico)
  --duration <s>          Duración en segundos (perfil dinámico)
  --shape <forma>         linear | constant | steps (perfil dinámico)
  --num-steps <n>         Escalones (solo si --shape steps, default: 5)

Opciones LIMBO:
  --threads <n>           Threads (default: 128)
  --warmup-duration <s>   Duración warmup en segundos (default: 30)
  --warmup-pause <s>      Pausa tras warmup en segundos (default: 5)
  --warmup-rate <r>       Carga durante warmup en req/s (default: 0.0)

Ejemplos:
  $0 exp01 1000 cpu,ram --profile low
  $0 exp02 1000 cpu,ram,sd,nic --profile high --categories 10 --products 200
  $0 exp03 500 cpu,ram --max-rps 200 --duration 180 --shape linear
EOF
    exit 0
}

# ─── Defaults ─────────────────────────────────────────────────────────────────
EXPERIMENT=""
INTERVAL_MS=""
COMPONENTS=""
CATEGORIES=5
PRODUCTS=100
USERS=100
ORDERS=5
PROFILE=""
MAX_RPS=""
DURATION_S=""
SHAPE=""
NUM_STEPS=5
THREADS=128
WARMUP_DURATION=30
WARMUP_PAUSE=5
WARMUP_RATE=0.0

# ─── Parseo de argumentos ─────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage
EXPERIMENT="$1"; shift
INTERVAL_MS="$1"; shift
COMPONENTS="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --categories)      CATEGORIES="$2";      shift 2 ;;
        --products)        PRODUCTS="$2";        shift 2 ;;
        --users)           USERS="$2";           shift 2 ;;
        --orders)          ORDERS="$2";          shift 2 ;;
        --profile)         PROFILE="$2";         shift 2 ;;
        --max-rps)         MAX_RPS="$2";         shift 2 ;;
        --duration)        DURATION_S="$2";      shift 2 ;;
        --shape)           SHAPE="$2";           shift 2 ;;
        --num-steps)       NUM_STEPS="$2";       shift 2 ;;
        --threads)         THREADS="$2";         shift 2 ;;
        --warmup-duration) WARMUP_DURATION="$2"; shift 2 ;;
        --warmup-pause)    WARMUP_PAUSE="$2";    shift 2 ;;
        --warmup-rate)     WARMUP_RATE="$2";     shift 2 ;;
        -h|--help)         usage ;;
        *) error "Parámetro desconocido: $1" ;;
    esac
done

# ─── Validaciones ─────────────────────────────────────────────────────────────
[[ -z "$EXPERIMENT" ]]  && error "Falta <experimento>"
[[ -z "$INTERVAL_MS" ]] && error "Falta <intervalo_ms>"
[[ -z "$COMPONENTS" ]]  && error "Falta <componentes>"
[[ -z "$PROFILE" && ( -z "$MAX_RPS" || -z "$DURATION_S" || -z "$SHAPE" ) ]] && \
    error "Debes especificar --profile O (--max-rps + --duration + --shape)"

# ─── Scripts requeridos — rutas desde .env ────────────────────────────────────
SCRIPTS_DIR="$SCRIPT_DIR"
DEPLOY_SCRIPT="$SCRIPTS_DIR/teastore-deploy.sh"
GENDB_SCRIPT="$SCRIPTS_DIR/teastore-gendb.sh"
ECOFLOC_WIDE="$SCRIPTS_DIR/run-ecofloc-wide.sh"
COLLECT_SCRIPT="$SCRIPTS_DIR/collect-results.sh"
LIMBO_SCRIPT="$SCRIPT_DIR/run-limbo.sh"

for S in "$DEPLOY_SCRIPT" "$GENDB_SCRIPT" "$ECOFLOC_WIDE" "$COLLECT_SCRIPT" "$LIMBO_SCRIPT"; do
    [[ -f "$S" ]] || error "Script no encontrado: $S"
done

# ─── Directorio de resultados y metadata ──────────────────────────────────────
RESULTS_DIR="$RESULTS_LOCAL_DIR/$EXPERIMENT"
mkdir -p "$RESULTS_DIR"
METADATA="$RESULTS_DIR/metadata.json"

# ─── Función: guardar timestamp de fase ───────────────────────────────────────
save_phase_ts() {
    local PHASE=$1
    local KEY=$2
    local TS=$3
    python3 - <<PYEOF
import json, os
path = "$METADATA"
data = json.load(open(path)) if os.path.exists(path) else {}
data.setdefault("phases", {}).setdefault("$PHASE", {})["$KEY"] = $TS
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# ─── Función: enviar señal a todos los nodos ──────────────────────────────────
_send_signal_to_all() {
    local SIGNAL_FILE=$1
    local SIGNAL_NAME=$2
    local i=1
    while true; do
        local NAME_VAR="NODE_${i}_NAME"
        local IP_VAR="NODE_${i}_IP"
        local NAME="${(P)NAME_VAR:-}"
        local IP="${(P)IP_VAR:-}"
        [[ -z "$NAME" || -z "$IP" ]] && break
        sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no ${SSH_USER}@$IP \
            "touch ${RESULTS_REMOTE_DIR}/$EXPERIMENT/$SIGNAL_FILE" 2>/dev/null || \
            warn "  ⚠ No se pudo enviar $SIGNAL_NAME a $NAME ($IP)"
        info "  → $SIGNAL_NAME enviado a $NAME ($IP)"
        (( i++ ))
    done
    # También local (control-plane)
    touch "${RESULTS_REMOTE_DIR}/$EXPERIMENT/$SIGNAL_FILE"
    info "  → $SIGNAL_NAME enviado a $(hostname 2>/dev/null || echo 'control-plane') (local)"
}

stop_ecofloc() {
    info "Enviando señal de parada a todos los nodos..."
    _send_signal_to_all ".stop" "stop"
}

redetect_ecofloc() {
    info "Enviando señal de re-detección a todos los nodos..."
    _send_signal_to_all ".redetect" "redetect"
}

# ─── Resumen inicial ──────────────────────────────────────────────────────────
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "  Experimento : $EXPERIMENT"
info "  Intervalo   : ${INTERVAL_MS}ms"
info "  Componentes : $COMPONENTS"
info "  BD          : cat=$CATEGORIES prod=$PRODUCTS usr=$USERS ord=$ORDERS"
if [[ -n "$PROFILE" ]]; then
    info "  Perfil      : $PROFILE"
else
    info "  Perfil      : ${SHAPE} ${MAX_RPS}rps ${DURATION_S}s"
fi
info "  Warmup      : ${WARMUP_DURATION}s @ ${WARMUP_RATE} req/s + ${WARMUP_PAUSE}s pausa"
info "  Threads     : $THREADS"
info "  Scripts dir : $SCRIPTS_DIR"
info "  Resultados  : $RESULTS_DIR"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Inicializar metadata.json
python3 - <<PYEOF
import json
data = {
    "experiment": "$EXPERIMENT",
    "interval_ms": $INTERVAL_MS,
    "components": "$COMPONENTS",
    "profile": "${PROFILE:-${SHAPE}_${MAX_RPS}rps_${DURATION_S}s}",
    "warmup_duration": $WARMUP_DURATION,
    "warmup_pause": $WARMUP_PAUSE,
    "warmup_rate": $WARMUP_RATE,
    "db": {
        "categories": $CATEGORIES,
        "products": $PRODUCTS,
        "users": $USERS,
        "orders": $ORDERS
    },
    "phases": {
        "deploy":   {"start_ts": None, "end_ts": None},
        "populate": {"start_ts": None, "end_ts": None},
        "workload": {"start_ts": None, "end_ts": None}
    }
}
with open("$METADATA", "w") as f:
    json.dump(data, f, indent=2)
print("  ✓ metadata.json inicializado")
PYEOF

# ─── Lanzar EcoFloc en todos los nodos (background) ──────────────────────────
phase "ECOFLOC — INICIO"
info "Lanzando EcoFloc en modo continuo en todos los nodos..."
"$ECOFLOC_WIDE" "$EXPERIMENT" "$INTERVAL_MS" "$COMPONENTS" &
ECOFLOC_PID=$!
info "EcoFloc Wide PID: $ECOFLOC_PID"

info "Esperando 15s para estabilización de EcoFloc (incluyendo NIC)..."
sleep 15
success "EcoFloc estabilizado — iniciando fases del experimento"

# ─── FASE: DEPLOY ─────────────────────────────────────────────────────────────
phase "DEPLOY"

DEPLOY_START=$(date +%s)
save_phase_ts "deploy" "start_ts" "$DEPLOY_START"
info "Deploy iniciado (ts=$DEPLOY_START)"

bash "$DEPLOY_SCRIPT"

DEPLOY_END=$(date +%s)
save_phase_ts "deploy" "end_ts" "$DEPLOY_END"
success "Deploy completado (ts=$DEPLOY_END, duración=$((DEPLOY_END - DEPLOY_START))s)"

info "Solicitando re-detección de PIDs TeaStore en todos los nodos..."
redetect_ecofloc
sleep 15

# ─── FASE: POPULATE ───────────────────────────────────────────────────────────
phase "POPULATE"

POPULATE_START=$(date +%s)
save_phase_ts "populate" "start_ts" "$POPULATE_START"
info "Populate iniciado (ts=$POPULATE_START)"

bash "$GENDB_SCRIPT" "$CATEGORIES" "$PRODUCTS" "$USERS" "$ORDERS"

POPULATE_END=$(date +%s)
save_phase_ts "populate" "end_ts" "$POPULATE_END"
success "Populate completado (ts=$POPULATE_END, duración=$((POPULATE_END - POPULATE_START))s)"

# ─── FASE: WORKLOAD ───────────────────────────────────────────────────────────
phase "WORKLOAD"

WORKLOAD_START=$(date +%s)
save_phase_ts "workload" "start_ts" "$WORKLOAD_START"
info "Workload iniciado (ts=$WORKLOAD_START)"

LIMBO_ARGS=("$EXPERIMENT")
if [[ -n "$PROFILE" ]]; then
    LIMBO_ARGS+=(--profile "$PROFILE")
else
    LIMBO_ARGS+=(--max-rps "$MAX_RPS" --duration "$DURATION_S" --shape "$SHAPE")
    [[ "$NUM_STEPS" -gt 0 ]] && LIMBO_ARGS+=(--num-steps "$NUM_STEPS")
fi
LIMBO_ARGS+=(
    --threads         "$THREADS"
    --warmup-duration "$WARMUP_DURATION"
    --warmup-pause    "$WARMUP_PAUSE"
    --warmup-rate     "$WARMUP_RATE"
)

"$LIMBO_SCRIPT" "${LIMBO_ARGS[@]}"

WORKLOAD_END=$(date +%s)
save_phase_ts "workload" "end_ts" "$WORKLOAD_END"
success "Workload completado (ts=$WORKLOAD_END, duración=$((WORKLOAD_END - WORKLOAD_START))s)"

# ─── PARAR ECOFLOC ────────────────────────────────────────────────────────────
phase "STOP ECOFLOC"

stop_ecofloc
info "Esperando que EcoFloc termine en todos los nodos..."
wait $ECOFLOC_PID 2>/dev/null || true
success "EcoFloc detenido en todos los nodos"

# ─── FASE: COLLECT ────────────────────────────────────────────────────────────
phase "COLLECT"

"$COLLECT_SCRIPT" "$EXPERIMENT"

# ─── RESUMEN FINAL ────────────────────────────────────────────────────────────
echo ""
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "  Experimento completado: $EXPERIMENT"
success "  Duración total: $((WORKLOAD_END - DEPLOY_START))s"
success "  Metadata : $METADATA"
success "  Resultados: $RESULTS_DIR"
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""