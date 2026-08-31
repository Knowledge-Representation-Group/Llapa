#!/usr/bin/env zsh
# cluster-status.sh — Estado del clúster Kubernetes + TeaStore + Kepler + Prometheus
# Lee nodos y configuración desde .env

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ENV_FILE="$SCRIPT_DIR/.env"
PROM_VALUES="$SCRIPT_DIR/../prometheus-config/prom-values.yaml"
KEPLER_SM="$SCRIPT_DIR/../prometheus-config/kepler-servicemonitor.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: no se encontró .env en $SCRIPT_DIR"
    exit 1
fi
source "$ENV_FILE"

echo "========================================="
echo " CLUSTER STATUS — $(date '+%Y-%m-%d %H:%M')"
echo "========================================="

# ─── NODOS ────────────────────────────────────────────────────────────────────
echo ""
echo "[ NODOS ]"
kubectl get nodes

# ─── CONTROL-PLANE PODS ───────────────────────────────────────────────────────
echo ""
echo "[ CONTROL-PLANE PODS ]"
kubectl get pods -n kube-system --no-headers | \
    awk '{printf "  %-45s STATUS:%-12s RESTARTS:%s\n", $1, $3, $4}'

# ─── TEASTORE ─────────────────────────────────────────────────────────────────
echo ""
echo "[ TEASTORE ]"
TS=$(kubectl get pods -n teastore --no-headers 2>/dev/null)
if [[ -z "$TS" ]]; then
    echo "  ⚠ TeaStore no desplegado"
    echo "  → Ejecuta: ./teastore-deploy.sh"
else
    echo "$TS" | awk '{printf "  %-45s STATUS:%-12s RESTARTS:%s\n", $1, $3, $4}'
    NOT_RUNNING=$(echo "$TS" | grep -v "Running" | wc -l)
    if [[ "$NOT_RUNNING" -gt 0 ]]; then
        echo ""
        echo "  ⚠ $NOT_RUNNING pod(s) no en Running — espera y vuelve a ejecutar"
    else
        WORKER_IP=$(kubectl get nodes --no-headers \
            | grep -v control-plane | grep "Ready" | awk '{print $1}' | head -1 \
            | xargs -I{} kubectl get node {} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        echo ""
        echo "  ✓ TeaStore OK — http://${WORKER_IP}:${TEASTORE_PORT}/tools.descartes.teastore.webui/"
    fi
fi

# ─── KEPLER ───────────────────────────────────────────────────────────────────
echo ""
echo "[ KEPLER ]"
KEPLER_DESIRED=$(kubectl get ds kepler -n kepler \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
KEPLER_READY=$(kubectl get ds kepler -n kepler \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)

if [[ "$KEPLER_DESIRED" -eq 0 ]]; then
    echo "  ⚠ Kepler no instalado — instalando..."
    helm install kepler oci://quay.io/sustainable_computing_io/charts/kepler \
        --namespace kepler --create-namespace
    echo "  Esperando que los pods arranquen..."
    kubectl rollout status ds/kepler -n kepler --timeout=120s
    echo "  ✓ Kepler instalado"
elif [[ "$KEPLER_READY" -lt "$KEPLER_DESIRED" ]]; then
    echo "  ⚠ Kepler parcialmente ready ($KEPLER_READY/$KEPLER_DESIRED) — esperando..."
    kubectl rollout status ds/kepler -n kepler --timeout=60s
else
    echo "  ✓ Kepler ($KEPLER_READY/$KEPLER_DESIRED pods ready)"
fi

# Verificar ServiceMonitor
SM=$(kubectl get servicemonitor kepler -n kepler --no-headers 2>/dev/null || echo "")
if [[ -z "$SM" ]]; then
    echo "  ⚠ ServiceMonitor no existe — aplicando..."
    if [[ -f "$KEPLER_SM" ]]; then
        kubectl apply -f "$KEPLER_SM"
        echo "  ✓ ServiceMonitor aplicado"
    else
        echo "  ✗ No se encontró $KEPLER_SM — créalo manualmente"
    fi
else
    echo "  ✓ ServiceMonitor kepler OK"
fi

# ─── PROMETHEUS + GRAFANA ─────────────────────────────────────────────────────
echo ""
echo "[ PROMETHEUS + GRAFANA ]"
PROM_READY=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
    | grep -c "Running" || echo 0)
PROM_TOTAL=$(kubectl get pods -n monitoring --no-headers 2>/dev/null \
    | wc -l || echo 0)

if [[ "$PROM_TOTAL" -eq 0 ]]; then
    echo "  ⚠ Prometheus/Grafana no instalado — instalando..."
    if [[ ! -f "$PROM_VALUES" ]]; then
        echo "  ✗ No se encontró $PROM_VALUES"
        echo "  → Crea Llapa/prometheus-config/prom-values.yaml antes de continuar"
        exit 1
    fi
    helm repo add prometheus-community \
        https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update
    helm install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring --create-namespace \
        -f "$PROM_VALUES"
    echo "  Esperando pods..."
    kubectl wait --for=condition=Ready pods \
        -l release=prometheus -n monitoring --timeout=120s 2>/dev/null || true
    echo "  ✓ Prometheus + Grafana instalados"
elif [[ "$PROM_READY" -lt "$PROM_TOTAL" ]]; then
    echo "  ⚠ Prometheus parcialmente ready ($PROM_READY/$PROM_TOTAL running)"
    kubectl get pods -n monitoring --no-headers | \
        awk '{printf "    %-55s %s\n", $1, $3}'
else
    echo "  ✓ Prometheus + Grafana ($PROM_READY/$PROM_TOTAL pods running)"
    echo "  → Grafana: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    echo "  → Prometheus: kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
fi

# ─── WORKERS ACCESIBLES ───────────────────────────────────────────────────────
echo ""
echo "[ WORKERS ACCESIBLES ]"
i=1
while true; do
    NAME_VAR="NODE_${i}_NAME"
    IP_VAR="NODE_${i}_IP"
    NAME="${(P)NAME_VAR:-}"
    IP="${(P)IP_VAR:-}"
    [[ -z "$NAME" || -z "$IP" ]] && break
    ping -c1 -W1 $IP &>/dev/null \
        && echo "  ✓ $NAME ($IP)" \
        || echo "  ✗ $NAME ($IP) — no responde"
    (( i++ ))
done

echo ""
echo "========================================="