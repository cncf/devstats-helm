# Installing cert-manager

Please make sure that you have DNS configured and ingress controller working with self-signed certs visible to the outside world on your domain.

- Create cert-manager namespace: `kubectl create namespace cert-manager`.
- Configure/label namespace: `kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true`.
- Install cert manager (includes CRDs): `kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.1.0/cert-manager.yaml`.
- Download prod/staging issuer(s) from `https://cert-manager.io/docs/configuration/acme/`.
- Compare ACME config from docs to example file then copy: `cp cert/cert-issuer.yaml.example cert/cert-issuer.yaml`.
- Tweak them - change email value: `vim cert/cert-issuer.yaml`, also set correct `nginx-class`, for example: `class: nginx-prod`.
- Apply issuers: `kubectl apply -f cert/cert-issuer.yaml`. Do not issue this before DNS is ready. If you've deployed DevStats ingress before this step, it will be ready with self-signed certificate.
- Check it: `kubectl get issuers`.
- Observer `k get challenge -w` wait until ready.

Troubleshooting/debugging:
- If you deployed DevStats before applying cert issuer, you need to delete devstats-ingress and recreate - it will pick up cert issuer and get its certificates.
- Eventually delete old secret with self-signed certificate: `kubectl delete secret devstats-tls`.
- `kubectl describe secret devstats-tls`, `kubectl get certificates`, `kubectl get order`, `kubectl describe order devstats-tls-xxx`.
- By default test server uses staging certificates that display warning, to change that update `cert/cert-issuer.yaml` to specify prod type issuer for test deployment and also use `sslEnv=prod` when creating ingress.
- In practice you must add prod-issuer on the devstats-test namespace, so special/test projects can also be accessible without SSL warning (and examples in test/README.txt assue this).


# Removing hints

- Sometimes `challenge` objects cannot be deleted, even with `--force --grace-period=0` flags, you should edit them and remove finalizers in such cases: `k edit challenge --all-namespaces`.
