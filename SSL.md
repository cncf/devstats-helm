# Installing cert-manager

Remember to set `KUBECONFIG`.

Please make sure that you have DNS configured and ingress controller working with self-signed certs visible to the outside world on your domain.

- Create cert-manager namespace: `kubectl create namespace cert-manager`.
- Configure/label namespace: `kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true`.
- Install cert manager (includes CRDs): `kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v0.8.0/cert-manager.yaml`.
- Download prod/staging issuer(s):
```
curl https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/docs/tutorials/acme/quick-start/example/production-issuer.yaml --output domain/cert-issuer-prod.yaml
curl https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/docs/tutorials/acme/quick-start/example/staging-issuer.yaml --output domain/cert-issuer-test.yaml
```
- Or use existing ones as an example: `cp cert/cert-issuer.yaml.example cert/cert-issuer.yaml`.
- Tweak them - change email value: `vim cert/cert-issuer.yaml`.
- Apply issuers: `kubectl apply -f cert/cert-issuer.yaml`. Do not issue this before DNS is ready. Your an deploy full DevStats before this step, Ingress will be ready with self-signed certificate.
- Check it: `kubectl get issuers`.
- If you deployed DevStats before applying cert issuer, you need to delete devstats-ingress and recreate - it will pick up cert issuer and get its certificates.
- Eventually delete old secret with self-signed certificate: `kubectl delete secret devstats-tls`.
- `kubectl describe secret devstats-tls`, `kubectl get certificates`, `kubectl get order`, `kubectl describe order devstats-tls-xxx`.
- By default test server uses staging certificates that display warning, to change that update `cert/cert-issuer.yaml` to specify prod type issuer for test deployment and also use `sslEnv=prod` when creating ingress.


# Helm approach

I had issues with Helm v3 installing this, so I'm just providing this as a reference:

- `kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/deploy/manifests/00-crds.yaml`.
- Needed only if `cert-manager` namespace already exists: `kubectl label namespace cert-manager certmanager.k8s.io/disable-validation="true"`.
- `helm repo add jetstack https://charts.jetstack.io`.
- `helm repo update`.
- `helm install cert-manager --namespace cert-manager jetstack/cert-manager`.

Reference: `https://github.com/jetstack/cert-manager/blob/master/docs/tutorials/acme/quick-start/index.rst`.
