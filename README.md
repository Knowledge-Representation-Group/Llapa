# Llapa-MAIN

This repository contains all the relevant information concerning the Llapa project. A monitor energy analysis focused on a multicomponent breakdown of computer systems.

## scripts

This folder contains some utils scripts to the k8s cluster.

1. cluster-status.sh -> get in a snapshot the nodes in the cluster and the current status of each one. The control-plane pods and teastore pods.
2. teastore-deploy.sh -> in case teastore is not deployed this script automatize this step, creating a namespace, and using the teastore ribbon from the TeaStore official github.
