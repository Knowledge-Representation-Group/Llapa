#!/bin/bash
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
if [ -z "$TS" ]; then
    echo "  ⚠ TeaStore no desplegado"
    echo "  → Ejecuta: ./teastore-deploy.sh"
else
    echo "$TS" | awk '{printf "  %-45s STATUS:%-12s RESTARTS:%s\n", $1, $3, $4}'
    NOT_RUNNING=$(echo "$TS" | grep -v "Running" | wc -l)
    if [ "$NOT_RUNNING" -gt 0 ]; then
        echo ""
        echo "  ⚠ $NOT_RUNNING pod(s) no en Running — espera y vuelve a ejecutar"
    else
        echo ""
        echo "  ✓ TeaStore OK — http://192.168.3.86:30080/tools.descartes.teastore.webui/"
    fi
fi

echo ""
echo "[ WORKERS ACCESIBLES ]"
for NODE in scorpius03:192.168.3.86 leo02:192.168.3.87 arrakis:192.168.3.89; do
    NAME=${NODE%:*}
    IP=${NODE#*:}
    ping -c1 -W1 $IP &>/dev/null \
        && echo "  ✓ $NAME ($IP)" \
        || echo "  ✗ $NAME ($IP) — no responde"
done

echo ""
echo "========================================="
