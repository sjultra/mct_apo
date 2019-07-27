#!/bin/bash

exec 3<&1
coproc mytee { tee loadgen_s1.log >&3;  }
exec >&${mytee[1]} 2>&1

if [ $# -lt 1 ]
then
  echo "Usage: $0 <time_in_seconds>"
  exit 1
fi

echo "Initialize Loadgenerator "
kubectl get nodes
cat /home/ubuntu/loadgen/loadgen_sameCluster.yaml
kubectl apply -f /home/ubuntu/loadgen/loadgen_sameCluster.yaml

kubectl get pods

echo "wait for pod to initialize"

i="$(kubectl get pods|grep -e 'Running\|CrashLoopBackOff'|wc -l)"
#while no of running statuses is not 2
while [ "$i" -ne 2 ]
do
  echo "pod is not Running sleep for 3s"
  i="$(kubectl get pods|grep -e 'Running\|CrashLoopBackOff'|wc -l)"
  sleep 3
done

kubectl get pods

# modify the value of this sleep
sleep $1

echo "Harvest logs from pod"
kubectl logs loadgen

echo "Currency logs:"
kubectl logs loadgen |grep setCurrency

kubectl get nodes

echo "Deleting pod"
kubectl delete pod loadgen

kubectl get pods
kubectl get nodes

