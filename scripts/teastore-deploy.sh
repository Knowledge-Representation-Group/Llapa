#!/usr/bin/env zsh
# teastore-deploy.sh — desplegar o re-desplegar TeaStore

echo "[ Creando namespace teastore si no existe ]"
kubectl create namespace teastore 2>/dev/null || echo "  namespace ya existe"

echo "[ Desplegando TeaStore (ribbon) ]"
kubectl apply -n teastore -f \
  https://raw.githubusercontent.com/DescartesResearch/TeaStore/master/examples/kubernetes/teastore-ribbon.yaml

echo ""
echo "[ Esperando a que los pods arranquen... ]"
kubectl wait --for=condition=Ready pod --all -n teastore --timeout=300s

echo ""

# Obtener IP de cualquier worker Ready para mostrar la URL
WORKER_IP=$(kubectl get nodes --no-headers \
    | grep -v control-plane \
    | grep "Ready" \
    | awk '{print $1}' \
    | head -1 \
    | xargs -I{} kubectl get node {} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

echo ""
echo "✓ TeaStore disponible en http://${WORKER_IP}:${TEASTORE_PORT}/tools.descartes.teastore.webui/"