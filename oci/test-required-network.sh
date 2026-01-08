#!/bin/bash
# Test ingress nodes
nc -vz -w 2 10.0.0.253 31080
nc -vz -w 2 10.0.0.53  31080
nc -vz -w 2 10.0.9.45  31080

nc -vz -w 2 10.0.0.253 31443
nc -vz -w 2 10.0.0.53  31443
nc -vz -w 2 10.0.9.45  31443

# Prod ingress nodes
nc -vz -w 2 10.0.0.223 30080
nc -vz -w 2 10.0.0.48  30080
nc -vz -w 2 10.0.27.190 30080

nc -vz -w 2 10.0.0.223 30443
nc -vz -w 2 10.0.0.48  30443
nc -vz -w 2 10.0.27.190 30443

