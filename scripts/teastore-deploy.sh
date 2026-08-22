#!/bin/bash
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
kubectl get pods -n teastore -o wide
echo ""
echo "✓ TeaStore disponible en http://192.168.3.86:30080/tools.descartes.teastore.webui/"
