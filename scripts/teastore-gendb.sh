#!/bin/bash
# teastore-gendb.sh — regenerar BD de TeaStore y esperar hasta que esté lista
# Uso: ./teastore-gendb.sh <categorias> <productos> <usuarios> <ordenes>
# Ejemplo: ./teastore-gendb.sh 5 100 100 5

CATEGORIES=${1:-5}
PRODUCTS=${2:-100}
USERS=${3:-100}
ORDERS=${4:-5}

# Obtener IP de cualquier worker Ready dinámicamente
HOST_IP=$(kubectl get nodes --no-headers \
  | grep -v control-plane \
  | grep "Ready" \
  | awk '{print $1}' \
  | head -1 \
  | xargs -I{} kubectl get node {} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

if [ -z "$HOST_IP" ]; then
    echo "✗ No hay workers Ready — verifica el clúster con ./cluster-status.sh"
    exit 1
fi

HOST="http://$HOST_IP:30080/tools.descartes.teastore.webui"
echo "[ Worker seleccionado: $HOST_IP ]"

echo "[ Regenerando BD TeaStore ]"
echo "  Categorías:        $CATEGORIES"
echo "  Productos/cat:     $PRODUCTS"
echo "  Usuarios:          $USERS"
echo "  Órdenes/usuario:   $ORDERS"
echo ""

curl -s -X POST "$HOST/dataBaseAction" \
  -d "categories=$CATEGORIES&products=$PRODUCTS&users=$USERS&orders=$ORDERS&confirm=Confirm" \
  -o /dev/null -w "HTTP status: %{http_code}\n"

echo ""
echo "[ Esperando a que la BD esté lista... ]"

while true; do
    STATUS=$(curl -s "$HOST/status")
    POPULATED=$(echo "$STATUS" | grep -c "OK and populated")
    TRAINED=$(echo "$STATUS"   | grep -c "OK and trained")

    if [ "$POPULATED" -ge 2 ] && [ "$TRAINED" -ge 1 ]; then
        echo "  ✓ BD lista — Persistence y Image pobladas, Recommender entrenado"
        break
    else
        echo "  ⏳ Poblando... (populated:$POPULATED/2, trained:$TRAINED/1)"
        sleep 5
    fi
done

echo ""
echo "✓ TeaStore listo en: $HOST/"