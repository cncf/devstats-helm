#!/bin/bash
# Rememeber to set correct kubectl parameters, for example AWS_PROFILE and/or KUBECONFIG
kubectl get secret
kubectl describe secret github-oauth grafana-secret pg-db
kubectl get cronjob
kubectl describe cronjob devstats-cncf devstats-prometheus
kubectl get sts
kubectl describe sts devstats-postgres
kubectl get svc
kubectl describe svc devstats-postgres devstats-postgres-config devstats-postgres-ro devstats-service-cncf devstats-service-prometheus
kubectl get deployment
kubectl describe deployment devstats-grafana-cncf devstats-grafana-prometheus
kubectl get endpoints
kubectl describe endpoints devstats-postgres devstats-postgres-config devstats-postgres-ro devstats-service-cncf devstats-service-prometheus
kubectl get pvc
kubectl describe pvc devstats-pvc-cncf devstats-pvc-prometheus pgdata-devstats-postgres-0 pgdata-devstats-postgres-1 pgdata-devstats-postgres-2
kubectl get rolebinding
kubectl describe rolebinding devstats-postgres
kubectl get role
kubectl describe role devstats-postgres
kubectl get serviceaccount
kubectl describe serviceaccount devstats-postgres
kubectl get ingress
kubectl describe ingress devstats-ingress
kubectl get po
kubectl describe po devstats-postgres-0 devstats-postgres-1 devstats-postgres-2 devstats-provision-cncf devstats-provision-prometheus
kubectl get events
