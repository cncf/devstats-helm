# Optional cStor OpenEBS storage (optional)

This is optional. You can setup a cStor OpenEBS storage (handles disk stripping/mirroring, replicas etc.)

- List your disks by calling `k get disks`. Then copy `cp openebs/cstor-pool-config.yaml.example openebs/cstor-pool-config.yaml` and add your disks there. Them `kubectl apply -f openebs/cstor-pool-config.yaml`. You will have a new StoragePoolClaim: `cstor-pool1`.
- Create storage class for newly createid cStor pool: `k apply -f openebs/cstor-storageclass.yaml`. You will have a new storage class: `openebs-disk-cstor`.

