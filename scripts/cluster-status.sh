#!/usr/bin/env zsh
# cluster-status.sh — Estado del clúster Kubernetes + TeaStore
# Lee nodos y configuración desde .env

set -uo pipefail

# ─── Cargar .env ──────────────────────────────────────────────────────────────
ENV_FILE="${0:A:h}/../../.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: no se encontró .env en ${0:A:h}"
    exit 1
fi
source "$ENV_FILE"

echo "========================================="
echo " CLUSTER STATUS — $(date '+%Y-%m-%d %H:%M')"
echo "========================================="

echo ""
echo "[ NODOS ]"
kubectl get nodes

echo ""
echo "[ CONTROL-PLANE PODS ]"
kubectl get pods -n kube-system --no-headers | \
    awk '{printf "  %-45s STATUS:%-12s RESTARTS:%s\n", $1, $3, $4}'

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
        # Obtener IP de cualquier worker para la URL
        WORKER_IP=$(kubectl get nodes --no-headers \
            | grep -v control-plane \
            | grep "Ready" \
            | awk '{print $1}' \
            | head -1 \
            | xargs -I{} kubectl get node {} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        echo ""
        echo "  ✓ TeaStore OK — http://${WORKER_IP}:${TEASTORE_PORT}/tools.descartes.teastore.webui/"
    fi
fi

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