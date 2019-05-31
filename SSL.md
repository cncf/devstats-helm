# Installing cert-manager

Remember to set `KUBECONFIG`.

Please make sure that you have DNS configured and ingress controlled working with self-signed certs visible to the outside world on your domain.

- `kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/deploy/manifests/00-crds.yaml`.
- Needed only if `cert-manager` namespace already exists: `kubectl label namespace cert-manager certmanager.k8s.io/disable-validation="true"`.
- `helm repo add jetstack https://charts.jetstack.io`.
- `helm repo update`.
- `helm install --name cert-manager --namespace cert-manager jetstack/cert-manager`.
- `curl https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/docs/tutorials/acme/quick-start/example/production-issuer.yaml --output domain/cert-issuer.yaml`.
- Edit issuer file (change emails etc.): `vim domain/cert-issuer.yaml`. You can also use `staging-issuer` instead of `production-issuer`.
- `kubectl apply -f domain/cert-issuer.yaml`. Do not issue this before DNS is ready. Youc an deploy full DevStats before this step, Ingress will be ready with self-signed certificate.
- Check it: `kubectl get issuers`.
- If you deployed DevStats before applying cert issuer, you need to delete devstats-ingress and recreate it - that's it - it will pick up cert issuer and get its certificates.
- Eventually delete old secret with self-signed certificate: `kubectl delete secret devstats-tls`.
- `kubectl describe secret devstats-tls`, `kubectl get certificates`, `kubectl get order`, `cncfkubectl.sh describe order devstats-tls-xxx`.

Reference: `https://github.com/jetstack/cert-manager/blob/master/docs/tutorials/acme/quick-start/index.rst`.
