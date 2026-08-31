#!/usr/bin/env zsh
# run-limbo.sh — Lanza LIMBO HTTP Load Generator (worker + director) en localhost
# Uso: ./run-limbo.sh <experimento> [opciones]
# Estructura esperada: <SCRIPT_DIR>/limbo-config/{httploadgenerator.jar, perfiles, lua}

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
LIMBO_DIR="$SCRIPT_DIR/../limbo-config"
JAR="$LIMBO_DIR/httploadgenerator.jar"

# ─── Colores ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo "${CYAN}[LIMBO]${NC} $*" }
success() { echo "${GREEN}[LIMBO]${NC} $*" }
warn()    { echo "${YELLOW}[LIMBO]${NC} $*" }
error()   { echo "${RED}[LIMBO] ERROR:${NC} $*" >&2; exit 1 }

# ─── Uso ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Uso: $0 <experimento> [opciones]

Argumentos:
  <experimento>           Nombre del experimento (se usa para carpeta de resultados)

Perfil de carga (elige uno):
  --profile <nombre>      Perfil predefinido: low | med | high | <nombre>.csv en limbo-config/
  --max-rps <n>           Máximo req/s (perfil dinámico)
  --duration <s>          Duración en segundos (perfil dinámico)
  --shape <forma>         Forma de carga: linear | constant | steps (perfil dinámico)
  --num-steps <n>         Número de escalones (solo si --shape steps, default: 5)

Opciones LIMBO:
  --threads <n>           Threads del load generator (default: 128)
  --warmup-duration <s>   Duración del warmup en segundos (default: 30)
  --warmup-pause <s>      Pausa tras warmup en segundos (default: 5)
  --warmup-rate <r>       Carga durante warmup en req/s (default: 0.0)
  --lua <archivo>         Script LUA (default: teastore_browse_ucsp.lua)
  --output <archivo>      Nombre del CSV de resultados (default: limbo_results.csv)

Ejemplos:
  $0 exp01 --profile low
  $0 exp02 --profile high --threads 256 --warmup-duration 60
  $0 exp03 --max-rps 200 --duration 180 --shape linear
  $0 exp04 --max-rps 50 --duration 120 --shape constant
  $0 exp05 --max-rps 100 --duration 150 --shape steps --num-steps 5
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
EXPERIMENT=""
PROFILE=""
MAX_RPS=""
DURATION_S=""
SHAPE=""
NUM_STEPS=5
THREADS=128
WARMUP_DURATION=30
WARMUP_PAUSE=5
WARMUP_RATE=0.0
LUA_SCRIPT="teastore_browse_ucsp.lua"
OUTPUT_FILE="limbo_results.csv"

# ─── Parseo de argumentos ───────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage
EXPERIMENT="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)         PROFILE="$2";         shift 2 ;;
        --max-rps)         MAX_RPS="$2";          shift 2 ;;
        --duration)        DURATION_S="$2";       shift 2 ;;
        --shape)           SHAPE="$2";            shift 2 ;;
        --num-steps)       NUM_STEPS="$2";        shift 2 ;;
        --threads)         THREADS="$2";          shift 2 ;;
        --warmup-duration) WARMUP_DURATION="$2";  shift 2 ;;
        --warmup-pause)    WARMUP_PAUSE="$2";     shift 2 ;;
        --warmup-rate)     WARMUP_RATE="$2";      shift 2 ;;
        --lua)             LUA_SCRIPT="$2";       shift 2 ;;
        --output)          OUTPUT_FILE="$2";      shift 2 ;;
        -h|--help)         usage ;;
        *) error "Parámetro desconocido: $1" ;;
    esac
done

# ─── Validaciones básicas ───────────────────────────────────────────────────
[[ -f "$JAR" ]] || error "No se encontró httploadgenerator.jar en $LIMBO_DIR"

# ─── Determinar perfil de carga ─────────────────────────────────────────────
PROFILE_FILE=""

if [[ -n "$PROFILE" ]]; then
    case "$PROFILE" in
        low)  PROFILE_FILE="$LIMBO_DIR/increasingLowIntensity.csv" ;;
        med)  PROFILE_FILE="$LIMBO_DIR/increasingMedIntensity.csv" ;;
        high) PROFILE_FILE="$LIMBO_DIR/increasingHighIntensity.csv" ;;
        *)
            if [[ -f "$LIMBO_DIR/${PROFILE}.csv" ]]; then
                PROFILE_FILE="$LIMBO_DIR/${PROFILE}.csv"
            elif [[ -f "$LIMBO_DIR/${PROFILE}" ]]; then
                PROFILE_FILE="$LIMBO_DIR/${PROFILE}"
            else
                error "Perfil '$PROFILE' no encontrado en $LIMBO_DIR"
            fi
            ;;
    esac

elif [[ -n "$MAX_RPS" && -n "$DURATION_S" && -n "$SHAPE" ]]; then
    [[ "$MAX_RPS" =~ ^[0-9]+(\.[0-9]+)?$ ]]     || error "--max-rps debe ser numérico"
    [[ "$DURATION_S" =~ ^[0-9]+$ ]]              || error "--duration debe ser entero"
    [[ "$SHAPE" =~ ^(linear|constant|steps)$ ]]  || error "--shape debe ser: linear | constant | steps"

    GENERATED_NAME="generated_${SHAPE}_${MAX_RPS}rps_${DURATION_S}s.csv"
    PROFILE_FILE="$LIMBO_DIR/$GENERATED_NAME"

    info "Generando perfil dinámico: $GENERATED_NAME"

    python3 - <<PYEOF
import csv, math

max_rps    = float("$MAX_RPS")
duration_s = int("$DURATION_S")
shape      = "$SHAPE"
num_steps  = int("$NUM_STEPS")
outfile    = "$PROFILE_FILE"

rows = []
for t in range(duration_s):
    time_mid = t + 0.5
    if shape == "linear":
        rate = max_rps * ((t + 1) / duration_s)
    elif shape == "constant":
        rate = max_rps
    elif shape == "steps":
        step_size  = max_rps / num_steps
        step_dur   = duration_s / num_steps
        step_index = min(int(t / step_dur), num_steps - 1)
        rate       = step_size * (step_index + 1)
    rows.append((time_mid, round(rate, 6)))

with open(outfile, "w", newline="") as f:
    writer = csv.writer(f)
    for row in rows:
        writer.writerow(row)

print(f"  → {len(rows)} intervalos generados, max rate: {rows[-1][1]} req/s")
PYEOF

    success "Perfil generado: $PROFILE_FILE"
else
    error "Debes especificar --profile O (--max-rps + --duration + --shape)"
fi

[[ -f "$PROFILE_FILE" ]] || error "Perfil no encontrado: $PROFILE_FILE"

# ─── Total de intervalos del perfil (para barra de progreso) ─────────────────
TOTAL_INTERVALS=$(wc -l < "$PROFILE_FILE")

# ─── Validar LUA ────────────────────────────────────────────────────────────
LUA_PATH="$LIMBO_DIR/$LUA_SCRIPT"
[[ -f "$LUA_PATH" ]] || error "Script LUA no encontrado: $LUA_PATH"

# ─── Preparar directorio de resultados ──────────────────────────────────────
RESULTS_DIR="${RESULTS_LOCAL_DIR}/$EXPERIMENT/limbo"
mkdir -p "$RESULTS_DIR"

# ─── Resumen del experimento ─────────────────────────────────────────────────
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "  Experimento : $EXPERIMENT"
info "  Perfil      : $PROFILE_FILE"
info "  LUA         : $LUA_SCRIPT"
info "  Threads     : $THREADS"
info "  Warmup      : ${WARMUP_DURATION}s @ ${WARMUP_RATE} req/s + ${WARMUP_PAUSE}s pausa"
info "  Output      : $RESULTS_DIR/$OUTPUT_FILE"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── Función barra de progreso ───────────────────────────────────────────────
draw_progress() {
    local current=$1
    local total=$2
    local rps=$3
    local success=$4
    local failed=$5

    local pct=$(( current * 100 / total ))
    local filled=$(( pct * 24 / 100 ))
    local empty=$(( 24 - filled ))

    local bar=""
    local i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done

    local failed_str=""
    if [[ $failed -gt 0 ]]; then
        failed_str=" ${RED}✗ ${failed}${NC}"
    fi

    printf "\r${CYAN}Progreso:${NC} [%s] %3d%% | t=%ds/%ds | %.0f req/s | ${GREEN}✓ %d${NC}%s   " \
        "$bar" "$pct" "$current" "$total" "$rps" "$success" "$failed_str"
}

# ─── Lanzar worker en background ────────────────────────────────────────────
info "Lanzando worker LIMBO en background..."
java -jar "$JAR" loadgenerator &> "$RESULTS_DIR/limbo_worker.log" &
WORKER_PID=$!
info "Worker PID: $WORKER_PID"
sleep 2

if ! kill -0 "$WORKER_PID" 2>/dev/null; then
    error "Worker LIMBO terminó inesperadamente. Ver: $RESULTS_DIR/limbo_worker.log"
fi

# ─── Lanzar director y parsear output en tiempo real ────────────────────────
info "Lanzando experimento...\n"

TOTAL_SUCCESS=0
TOTAL_FAILED=0
LAST_RPS=0
CURRENT_T=0
DIRECTOR_EXIT=0

java -jar "$JAR" director \
    -s 127.0.0.1 \
    -a "$PROFILE_FILE" \
    -l "$LUA_PATH" \
    -o "$OUTPUT_FILE" \
    -t "$THREADS" \
    --warmup-duration "$WARMUP_DURATION" \
    --warmup-pause    "$WARMUP_PAUSE" \
    --warmup-rate     "$WARMUP_RATE" 2>&1 | while IFS= read -r line; do
        echo "$line" >> "$RESULTS_DIR/limbo_director.log"

        if [[ "$line" =~ "Target Time = ([0-9]+\.[0-9]+); Load Intensity = ([0-9]+\.[0-9]+); #Success = ([0-9]+); #Failed = ([0-9]+)" ]]; then
            CURRENT_T=${match[1]%.*}
            LAST_RPS=${match[2]%.*}
            TOTAL_SUCCESS=$(( TOTAL_SUCCESS + match[3] ))
            TOTAL_FAILED=$(( TOTAL_FAILED + match[4] ))
            draw_progress "$CURRENT_T" "$TOTAL_INTERVALS" "$LAST_RPS" "$TOTAL_SUCCESS" "$TOTAL_FAILED"
        fi
    done || DIRECTOR_EXIT=$?

echo ""  # nueva línea tras la barra

# ─── Mover resultado al directorio del experimento ──────────────────────────
LIMBO_OUTPUT="$LIMBO_DIR/$OUTPUT_FILE"
if [[ -f "$LIMBO_OUTPUT" ]]; then
    mv "$LIMBO_OUTPUT" "$RESULTS_DIR/$OUTPUT_FILE"
else
    warn "No se encontró $LIMBO_OUTPUT — el CSV puede no haberse generado"
fi

# ─── Cleanup worker ─────────────────────────────────────────────────────────
if kill -0 "$WORKER_PID" 2>/dev/null; then
    info "Deteniendo worker (PID $WORKER_PID)..."
    kill "$WORKER_PID" 2>/dev/null
    wait "$WORKER_PID" 2>/dev/null || true
fi

# ─── Resumen final ───────────────────────────────────────────────────────────
if [[ $DIRECTOR_EXIT -eq 0 ]]; then
    echo ""
    success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    success "  Experimento completado"
    success "  Total requests  : $TOTAL_SUCCESS"
    success "  Failed          : $TOTAL_FAILED"
    success "  Resultados      : $RESULTS_LOCAL_DIR/$EXPERIMENT/limbo"
    success "  Log director    : $RESULTS_DIR/limbo_director.log"
    success "  Log worker      : $RESULTS_DIR/limbo_worker.log"
    success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    error "Director terminó con error (código $DIRECTOR_EXIT). Ver: $RESULTS_DIR/limbo_director.log"
fi