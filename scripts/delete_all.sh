#!/bin/bash
# Rememeber to set correct kubectl parameters: KUBECONFIG
kubectl delete secret pg-db github-oauth grafana-secret
../devstats-k8s-lf/util/delete_objects.sh ingress 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh cronjob 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh statefulset 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh service 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh deployment 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh endpoints 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh configmap 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh pod 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh pvc 'pgdata-devstats-'
../devstats-k8s-lf/util/delete_objects.sh pvc 'devstats-pvc-'
../devstats-k8s-lf/util/delete_objects.sh rolebinding 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh role 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh serviceaccount 'devstats-'
../devstats-k8s-lf/util/delete_objects.sh secret 'devstats-'
