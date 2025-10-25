#!/bin/bash
kubectl create namespace net-diag

kubectl apply -n net-diag -f - <<'YAML'
apiVersion: v1
kind: List
items:
# --- Bash Pod A ---
- apiVersion: v1
  kind: Pod
  metadata:
    name: bash-a
    labels: { app: bash-diag, who: a }
  spec:
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels: { app: bash-diag }
          topologyKey: kubernetes.io/hostname
    containers:
    - name: shell
      image: ubuntu:24.04
      command: ["bash","-lc"]
      args:
      - |
        apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y iputils-ping wget curl dnsutils netcat-traditional && \
        echo READY && sleep infinity
      stdin: true
      tty: true
    restartPolicy: Always

# --- Bash Pod B ---
- apiVersion: v1
  kind: Pod
  metadata:
    name: bash-b
    labels: { app: bash-diag, who: b }
  spec:
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels: { app: bash-diag }
          topologyKey: kubernetes.io/hostname
    containers:
    - name: shell
      image: ubuntu:24.04
      command: ["bash","-lc"]
      args:
      - |
        apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y iputils-ping wget curl dnsutils netcat-traditional && \
        echo READY && sleep infinity
      stdin: true
      tty: true
    restartPolicy: Always

# --- Nginx Deployment ---
- apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: web
  spec:
    replicas: 1
    selector:
      matchLabels: { app: web }
    template:
      metadata:
        labels: { app: web }
      spec:
        containers:
        - name: nginx
          image: nginx:alpine
          ports:
          - containerPort: 80

# --- Service to expose nginx (NodePort gives you ClusterIP + nodeIP:nodePort) ---
- apiVersion: v1
  kind: Service
  metadata:
    name: nginx-svc
  spec:
    type: NodePort
    selector: { app: web }
    ports:
    - name: http
      port: 80
      targetPort: 80
      nodePort: 32080  # choose a fixed port in 30000-32767; change if you like
YAML

echo -n 'wait 30 seconds ... '
sleep 30
echo 'ok'

kubectl -n net-diag get pods -o wide
# Pod IPs and names
kubectl -n net-diag get pod -o wide

A=$(kubectl -n net-diag get pod bash-a -o jsonpath='{.status.podIP}')
B=$(kubectl -n net-diag get pod bash-b -o jsonpath='{.status.podIP}')
NGPOD=$(kubectl -n net-diag get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
NGIP=$(kubectl -n net-diag get pod "$NGPOD" -o jsonpath='{.status.podIP}')
SVCIP=$(kubectl -n net-diag get svc nginx-svc -o jsonpath='{.spec.clusterIP}')
NODEPORT=$(kubectl -n net-diag get svc nginx-svc -o jsonpath='{.spec.ports[0].nodePort}')
NODE0=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "A=$A  B=$B  NGIP=$NGIP  SVCIP=$SVCIP  NODEPORT=$NODEPORT  NODE0=$NODE0"

kubectl -n net-diag exec -it bash-a -- bash -lc "
  echo '== ping B ('$B') =='; ping -c2 $B;
  echo '== nc -> B:8080 sanity (should fail if no listener) =='; (echo hi | nc -w2 $B 8080 || true)
"

kubectl -n net-diag exec -it bash-a -- bash -lc "
  echo '== DNS for nginx-svc =='; dig +short nginx-svc.net-diag.svc.cluster.local;
  echo '== curl ClusterIP ==';   curl -sS http://$SVCIP/ | head -n1;
  echo '== curl Service FQDN =='; curl -sS http://nginx-svc.net-diag.svc.cluster.local/ | head -n1
"

kubectl -n net-diag exec -it bash-a -- bash -lc "
  echo '== curl nginx Pod IP =='; curl -sS http://$NGIP/ | head -n1
"

kubectl -n net-diag exec -it bash-a -- bash -lc "
  echo '== curl nodeIP:nodePort =='; curl -sS http://$NODE0:$NODEPORT/ | head -n1
"

kubectl -n net-diag exec -it bash-a -- bash -lc "
  echo '== ping 1.1.1.1 =='; ping -c2 1.1.1.1;
  echo '== wget example.com =='; wget -qO- https://example.com | head -n3
"

kubectl -n net-diag exec -it bash-b -- bash -lc "
  echo '== ping A ('$A') =='; ping -c2 $A;
  echo '== curl Service FQDN =='; curl -sS http://nginx-svc.net-diag.svc.cluster.local/ | head -n1
"

kubectl -n net-diag get pod -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP

kubectl delete namespace net-diag

