#!/bin/bash
echo "Token: $(kubectl -n headlamp get secret headlamp-ro-token -o jsonpath='{.data.token}' | base64 -d)"
kubectl -n headlamp port-forward svc/headlamp 8080:80
