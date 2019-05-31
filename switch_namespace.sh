#!/bin/bash
export KUBECONFIG=/root/.kube/config_cncf
if [ -z "$1" ]
then
  echo "$0: you need to provide namespace name as an argument, use 'default' to switch to the default namespace"
  exit 1
fi

kubectl config set-context $(kubectl config current-context) --namespace="$1"
kubectl config view | grep namespace
