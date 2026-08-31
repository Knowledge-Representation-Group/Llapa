#!/usr/bin/env zsh
# run-experiment.sh — Orquestador principal del experimento TeaStore + EcoFloc/Kepler/Scaphandre
# Uso: ./run-experiment.sh <experimento> <intervalo_ms> <componentes> [opciones]

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
[[ -f "$ENV_FILE" ]] || error "No se encontró .env en $ENV_FILE"
set -a; source "$ENV_FILE"; set +a

# ─── Uso ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Uso: $0 <experimento> <intervalo_ms> <componentes> [opciones]

Argumentos obligatorios:
  <experimento>           Nombre del experimento
  <intervalo_ms>          Intervalo de muestreo EcoFloc en ms (ej: 1000)
                          Para scaphandre se convierte a segundos automáticamente
  <componentes>           Componentes EcoFloc: cpu,ram,sd,nic
                          (ignorado si --monitor kepler o scaphandre)

Monitorización:
  --monitor <tool>        Herramienta(s): ecofloc | kepler | scaphandre |
                          ecofloc,kepler | ecofloc,scaphandre | kepler,scaphandre |
                          ecofloc,kepler,scaphandre
                          (default: ecofloc)
  --prom-url <url>        URL de Prometheus (default: http://localhost:9090)

Parámetros BD:
  --categories <n>        Categorías (default: 5)
  --products <n>          Productos por categoría (default: 100)
  --users <n>             Usuarios (default: 100)
  --orders <n>            Órdenes por usuario (default: 5)

Perfil de carga LIMBO (elige uno):
  --profile <nombre>      Perfil predefinido: low | med | high | <nombre>.csv
  --max-rps <n>           Máximo req/s (perfil dinámico)
  --duration <s>          Duración en segundos (perfil dinámico)
  --shape <forma>         linear | constant | steps
  --num-steps <n>         Escalones (solo si --shape steps, default: 5)

Opciones LIMBO:
  --threads <n>           Threads (default: 128)
  --warmup-duration <s>   Duración warmup (default: 30)
  --warmup-pause <s>      Pausa tras warmup (default: 5)
  --warmup-rate <r>       Carga durante warmup (default: 0.0)

Ejemplos:
  $0 exp01 5000 cpu,ram,sd,nic --profile low --monitor ecofloc
  $0 exp02 5000 cpu,ram,sd,nic --profile low --monitor kepler
  $0 exp03 5000 cpu,ram,sd,nic --profile low --monitor scaphandre
  $0 exp04 5000 cpu,ram,sd,nic --profile low --monitor ecofloc,kepler
  $0 exp05 5000 cpu,ram,sd,nic --profile low --monitor ecofloc,scaphandre
  $0 exp06 5000 cpu,ram,sd,nic --profile low --monitor ecofloc,kepler,scaphandre
EOF
    exit 0
}

# ─── Defaults ─────────────────────────────────────────────────────────────────
EXPERIMENT=""
INTERVAL_MS=""
COMPONENTS=""
MONITOR="ecofloc"
PROM_URL="${PROM_URL:-http://localhost:9090}"
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
        --monitor)         MONITOR="$2";          shift 2 ;;
        --prom-url)        PROM_URL="$2";         shift 2 ;;
        --categories)      CATEGORIES="$2";       shift 2 ;;
        --products)        PRODUCTS="$2";         shift 2 ;;
        --users)           USERS="$2";            shift 2 ;;
        --orders)          ORDERS="$2";           shift 2 ;;
        --profile)         PROFILE="$2";          shift 2 ;;
        --max-rps)         MAX_RPS="$2";          shift 2 ;;
        --duration)        DURATION_S="$2";       shift 2 ;;
        --shape)           SHAPE="$2";            shift 2 ;;
        --num-steps)       NUM_STEPS="$2";        shift 2 ;;
        --threads)         THREADS="$2";          shift 2 ;;
        --warmup-duration) WARMUP_DURATION="$2";  shift 2 ;;
        --warmup-pause)    WARMUP_PAUSE="$2";     shift 2 ;;
        --warmup-rate)     WARMUP_RATE="$2";      shift 2 ;;
        -h|--help)         usage ;;
        *) error "Parámetro desconocido: $1" ;;
    esac
done

# ─── Flags de monitor ─────────────────────────────────────────────────────────
USE_ECOFLOC=false
USE_KEPLER=false
USE_SCAPHANDRE=false
[[ "$MONITOR" == *"ecofloc"*     ]] && USE_ECOFLOC=true
[[ "$MONITOR" == *"kepler"*      ]] && USE_KEPLER=true
[[ "$MONITOR" == *"scaphandre"*  ]] && USE_SCAPHANDRE=true
($USE_ECOFLOC || $USE_KEPLER || $USE_SCAPHANDRE) || \
    error "--monitor debe contener: ecofloc, kepler, scaphandre (o combinación)"

# Intervalo scaphandre en segundos (convierte desde ms)
INTERVAL_S=$(( INTERVAL_MS / 1000 ))
[[ "$INTERVAL_S" -lt 1 ]] && INTERVAL_S=1

# ─── Validaciones ─────────────────────────────────────────────────────────────
[[ -z "$EXPERIMENT" ]]  && error "Falta <experimento>"
[[ -z "$INTERVAL_MS" ]] && error "Falta <intervalo_ms>"
[[ -z "$COMPONENTS" ]]  && error "Falta <componentes>"
[[ -z "$PROFILE" && ( -z "$MAX_RPS" || -z "$DURATION_S" || -z "$SHAPE" ) ]] && \
    error "Debes especificar --profile O (--max-rps + --duration + --shape)"

# ─── Scripts requeridos ───────────────────────────────────────────────────────
SCRIPTS_DIR="$SCRIPT_DIR"
DEPLOY_SCRIPT="$SCRIPTS_DIR/teastore-deploy.sh"
GENDB_SCRIPT="$SCRIPTS_DIR/teastore-gendb.sh"
ECOFLOC_WIDE="$SCRIPTS_DIR/run-ecofloc-wide.sh"
SCAPH_WIDE="$SCRIPTS_DIR/run-scaphandre-wide.sh"
COLLECT_SCRIPT="$SCRIPTS_DIR/collect-results.sh"
LIMBO_SCRIPT="$SCRIPTS_DIR/run-limbo.sh"
KEPLER_EXPORT="$SCRIPTS_DIR/export-kepler.sh"

for S in "$DEPLOY_SCRIPT" "$GENDB_SCRIPT" "$COLLECT_SCRIPT" "$LIMBO_SCRIPT"; do
    [[ -f "$S" ]] || error "Script no encontrado: $S"
done
$USE_ECOFLOC     && { [[ -f "$ECOFLOC_WIDE"  ]] || error "Script no encontrado: $ECOFLOC_WIDE";  }
$USE_KEPLER      && { [[ -f "$KEPLER_EXPORT" ]] || error "Script no encontrado: $KEPLER_EXPORT"; }
$USE_SCAPHANDRE  && { [[ -f "$SCAPH_WIDE"    ]] || error "Script no encontrado: $SCAPH_WIDE";    }

# ─── Directorio de resultados y metadata ──────────────────────────────────────
RESULTS_DIR="$RESULTS_LOCAL_DIR/$EXPERIMENT"
mkdir -p "$RESULTS_DIR"
METADATA="$RESULTS_DIR/metadata.json"

# ─── Helpers ──────────────────────────────────────────────────────────────────
save_phase_ts() {
    local PHASE=$1 KEY=$2 TS=$3
    python3 - <<PYEOF
import json, os
path = "$METADATA"
data = json.load(open(path)) if os.path.exists(path) else {}
data.setdefault("phases", {}).setdefault("$PHASE", {})["$KEY"] = $TS
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

_send_signal_to_all() {
    local SIGNAL_FILE=$1 SIGNAL_NAME=$2
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
    touch "${RESULTS_REMOTE_DIR}/$EXPERIMENT/$SIGNAL_FILE"
    info "  → $SIGNAL_NAME enviado a $(cat /etc/hostname 2>/dev/null || echo 'control-plane') (local)"
}

stop_ecofloc()     { info "Enviando señal stop...";      _send_signal_to_all ".stop"     "stop"     }
redetect_ecofloc() { info "Enviando señal redetect...";  _send_signal_to_all ".redetect" "redetect" }

# ─── Resumen inicial ──────────────────────────────────────────────────────────
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "  Experimento : $EXPERIMENT"
info "  Monitor     : $MONITOR"
info "  Intervalo   : ${INTERVAL_MS}ms (scaphandre: ${INTERVAL_S}s)"
info "  Componentes : $COMPONENTS"
info "  BD          : cat=$CATEGORIES prod=$PRODUCTS usr=$USERS ord=$ORDERS"
if [[ -n "$PROFILE" ]]; then
    info "  Perfil      : $PROFILE"
else
    info "  Perfil      : ${SHAPE} ${MAX_RPS}rps ${DURATION_S}s"
fi
info "  Warmup      : ${WARMUP_DURATION}s @ ${WARMUP_RATE} req/s + ${WARMUP_PAUSE}s pausa"
info "  Threads     : $THREADS"
info "  Resultados  : $RESULTS_DIR"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Inicializar metadata.json
python3 - <<PYEOF
import json
data = {
    "experiment":      "$EXPERIMENT",
    "monitor":         "$MONITOR",
    "interval_ms":     $INTERVAL_MS,
    "components":      "$COMPONENTS",
    "profile":         "${PROFILE:-${SHAPE}_${MAX_RPS}rps_${DURATION_S}s}",
    "warmup_duration": $WARMUP_DURATION,
    "warmup_pause":    $WARMUP_PAUSE,
    "warmup_rate":     $WARMUP_RATE,
    "db": {
        "categories": $CATEGORIES,
        "products":   $PRODUCTS,
        "users":      $USERS,
        "orders":     $ORDERS
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

# ─── FASE: ECOFLOC INICIO ────────────────────────────────────────────────────
if $USE_ECOFLOC; then
    phase "ECOFLOC — INICIO"
    info "Lanzando EcoFloc en modo continuo en todos los nodos..."
    "$ECOFLOC_WIDE" "$EXPERIMENT" "$INTERVAL_MS" "$COMPONENTS" &
    ECOFLOC_PID=$!
    info "EcoFloc Wide PID: $ECOFLOC_PID"
    info "Esperando 15s para estabilización..."
    sleep 15
    success "EcoFloc estabilizado"
fi

# ─── FASE: SCAPHANDRE INICIO ─────────────────────────────────────────────────
if $USE_SCAPHANDRE; then
    phase "SCAPHANDRE — INICIO"
    info "Lanzando Scaphandre en modo continuo en todos los nodos..."
    "$SCAPH_WIDE" "$EXPERIMENT" "$INTERVAL_S" &
    SCAPH_WIDE_PID=$!
    info "Scaphandre Wide PID: $SCAPH_WIDE_PID"
    info "Esperando 10s para estabilización..."
    sleep 10
    success "Scaphandre estabilizado"
fi

# ─── FASE: KEPLER VERIFICACIÓN ───────────────────────────────────────────────
if $USE_KEPLER; then
    phase "KEPLER — VERIFICACIÓN"
    if ! curl -sf "${PROM_URL}/api/v1/query" --data-urlencode 'query=up' > /dev/null 2>&1; then
        warn "Prometheus no accesible en $PROM_URL — abriendo port-forward..."
        kubectl port-forward -n monitoring \
            svc/prometheus-kube-prometheus-prometheus 9090:9090 &
        PROM_PF_PID=$!
        sleep 5
        curl -sf "${PROM_URL}/api/v1/query" --data-urlencode 'query=up' > /dev/null 2>&1 \
            || error "Prometheus sigue inaccesible tras port-forward"
    else
        PROM_PF_PID=""
    fi
    success "Prometheus accesible en $PROM_URL"
fi

# ─── FASE: DEPLOY ─────────────────────────────────────────────────────────────
phase "DEPLOY"
DEPLOY_START=$(date +%s)
DEPLOY_START_LOCAL=$(date '+%Y-%m-%d %H:%M:%S')
save_phase_ts "deploy" "start_ts" "$DEPLOY_START"
bash "$DEPLOY_SCRIPT"
DEPLOY_END=$(date +%s)
save_phase_ts "deploy" "end_ts" "$DEPLOY_END"
success "Deploy completado (${$(( DEPLOY_END - DEPLOY_START ))}s)"

if $USE_ECOFLOC; then
    info "Re-detección de PIDs TeaStore..."
    redetect_ecofloc
    sleep 15
fi

# ─── FASE: POPULATE ───────────────────────────────────────────────────────────
phase "POPULATE"
POPULATE_START=$(date +%s)
save_phase_ts "populate" "start_ts" "$POPULATE_START"
bash "$GENDB_SCRIPT" "$CATEGORIES" "$PRODUCTS" "$USERS" "$ORDERS"
POPULATE_END=$(date +%s)
save_phase_ts "populate" "end_ts" "$POPULATE_END"
success "Populate completado (${$(( POPULATE_END - POPULATE_START ))}s)"

# ─── FASE: WORKLOAD ───────────────────────────────────────────────────────────
phase "WORKLOAD"
WORKLOAD_START=$(date +%s)
WORKLOAD_START_LOCAL=$(date '+%Y-%m-%d %H:%M:%S')
save_phase_ts "workload" "start_ts" "$WORKLOAD_START"
info "Workload iniciado: $WORKLOAD_START_LOCAL"

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
WORKLOAD_END_LOCAL=$(date '+%Y-%m-%d %H:%M:%S')
save_phase_ts "workload" "end_ts" "$WORKLOAD_END"
success "Workload completado: $WORKLOAD_END_LOCAL (${$(( WORKLOAD_END - WORKLOAD_START ))}s)"

# ─── PARAR ECOFLOC ────────────────────────────────────────────────────────────
if $USE_ECOFLOC; then
    phase "STOP ECOFLOC"
    stop_ecofloc
    info "Esperando que EcoFloc termine..."
    wait $ECOFLOC_PID 2>/dev/null || true
    success "EcoFloc detenido"
fi

# ─── PARAR SCAPHANDRE ─────────────────────────────────────────────────────────
if $USE_SCAPHANDRE; then
    phase "STOP SCAPHANDRE"
    info "Enviando señal stop a Scaphandre..."
    # Reusar _send_signal_to_all — scaphandre también monitorea .stop
    _send_signal_to_all ".stop" "stop"
    info "Esperando que Scaphandre termine..."
    wait $SCAPH_WIDE_PID 2>/dev/null || true
    success "Scaphandre detenido"
fi

# ─── FASE: COLLECT ECOFLOC ────────────────────────────────────────────────────
if $USE_ECOFLOC; then
    phase "COLLECT — ECOFLOC"
    "$COLLECT_SCRIPT" "$EXPERIMENT"
fi

# ─── FASE: COLLECT SCAPHANDRE ─────────────────────────────────────────────────
if $USE_SCAPHANDRE; then
    phase "COLLECT — SCAPHANDRE"
    info "Recolectando JSONs de Scaphandre desde workers..."
    local i=1
    while true; do
        local NAME_VAR="NODE_${i}_NAME"
        local IP_VAR="NODE_${i}_IP"
        local NAME="${(P)NAME_VAR:-}"
        local IP="${(P)IP_VAR:-}"
        [[ -z "$NAME" || -z "$IP" ]] && break
        mkdir -p "$RESULTS_DIR/scaphandre"
        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no \
            "${SSH_USER}@${IP}:${RESULTS_REMOTE_DIR}/${EXPERIMENT}/scaphandre/*.json" \
            "$RESULTS_DIR/scaphandre/" 2>/dev/null && \
            info "  ✓ JSON de $NAME copiado" || \
            warn "  ⚠ No se pudo copiar JSON de $NAME"
        (( i++ ))
    done
    # muaddib — ya está local
    info "  ✓ JSON de muaddib ya disponible localmente"
    success "Scaphandre JSONs recolectados en $RESULTS_DIR/scaphandre/"
fi

# ─── FASE: EXPORT KEPLER ──────────────────────────────────────────────────────
if $USE_KEPLER; then
    phase "COLLECT — KEPLER"
    info "Exportando métricas Kepler..."
    info "  Rango: $DEPLOY_START_LOCAL → $WORKLOAD_END_LOCAL"

    PROM_URL="$PROM_URL" bash "$KEPLER_EXPORT" \
        "$EXPERIMENT" \
        "$DEPLOY_START_LOCAL" \
        "$WORKLOAD_END_LOCAL"

    if [[ -n "${PROM_PF_PID:-}" ]]; then
        kill "$PROM_PF_PID" 2>/dev/null || true
        info "Port-forward Prometheus cerrado"
    fi
fi

# ─── RESUMEN FINAL ────────────────────────────────────────────────────────────
echo ""
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "  Experimento completado : $EXPERIMENT"
success "  Monitor                : $MONITOR"
success "  Workload               : $WORKLOAD_START_LOCAL → $WORKLOAD_END_LOCAL"
success "  Duración total         : $((WORKLOAD_END - DEPLOY_START))s"
success "  Metadata               : $METADATA"
success "  Resultados             : $RESULTS_DIR"
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""