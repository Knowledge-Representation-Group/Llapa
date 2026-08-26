# Llapa

This repository contains all the relevant information concerning the Llapa project. A monitor energy analysis focused on a multicomponent breakdown of computer systems.

## scripts

This folder contains some utils scripts to the k8s cluster.

### Cluster k8s scripts

1. cluster-status.sh > get in a snapshot the nodes in the cluster and the current status of each one. The control-plane pods and teastore pods.

### Ecofloc scripts

2. run-ecofloc.sh > run ecofloc aislating pids of the teastore services, it can be measure in duration / interval / components to measure

3. run-ecofloc-wide.sh > execute run-ecofloc.sh paralel in the nodes of the cluster it works with a .env file for passwords sudo of each node or ssh connections using the sshpass package of arch linux

### Teastore scripts

4. teastore-deploy.sh > in case teastore is not deployed this script automatize this step, creating a namespace, and using the teastore ribbon from the TeaStore official github.

5. teastore-gendb.sh > regenerates the database with the desired configuration in categories, products, users, orders

### Experiment scripts

6. run-limbo.sh > the teastore accepts different workload generators we use limbo as its the most configurable. This script launch the limbo worklaod generator using the configuration in the limbo-config folder. It needs the .jar, the profile that uses inside teastore aka the operations the user make and the intensity of requests.

7. run-experiment.sh > execute an experiment with ecofloc as a primary energy monitor trought out it. it has different parameters that can manipulate the db-teastore settings or the limbo workload generator.

8. collect-results.sh > recollects the result files of ecofloc in each node to the central node to postprocessing. uses the .env file as well.

9. consolidate.py > script in python that produces a csv file of energy levels based on the folder structure that collect-results.sh gives.
