# Llapa-MAIN

This repository contains all the relevant information concerning the Llapa project. A monitor energy analysis focused on a multicomponent breakdown of computer systems.

## scripts

This folder contains some utils scripts to the k8s cluster.

1. cluster-status.sh > get in a snapshot the nodes in the cluster and the current status of each one. The control-plane pods and teastore pods.
2. teastore-deploy.sh > in case teastore is not deployed this script automatize this step, creating a namespace, and using the teastore ribbon from the TeaStore official github.
3. teastore-gendb.sh > regenerates the database with the desired configuration in categories, products, users, orders
4. run-ecofloc.sh > run ecofloc aislating pids of the teastore services, it can be measure in duration / interval / components to measure
5. experiment.sh > execute run-ecofloc.sh paralel in the nodes of the cluster it works with a .env file for passwords sudo of each node or ssh connections using the sshpass package of arch linux
6. collect-results.sh > recollects the result files of ecofloc in each node to the central node to postprocessing. uses the .env file as well.
