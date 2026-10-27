# storage

Defines the StorageClass `platform-data`, used by every data component. The class differs per cloud (values overlays) while the charts that use it do not.

| Cloud | Provisioner | Volume type |
| --- | --- | --- |
| EKS | `ebs.csi.aws.com` | gp3, encrypted |
| GKE | `pd.csi.storage.gke.io` | pd-balanced |

`reclaimPolicy: Delete` means the cloud disk is deleted when its PersistentVolumeClaim is. `WaitForFirstConsumer` creates the disk in the zone where the pod is scheduled. The class is not the cluster default. Volumes are **not** managed by Terraform and are not removed by `terraform destroy`: delete the claims first (see the [data layer runbook](../../../docs/runbooks/data-layer.md)).
