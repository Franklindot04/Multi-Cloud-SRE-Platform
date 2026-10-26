# aws-load-balancer-controller

Provisions ALBs for `Ingress` resources (class `alb`) and NLBs for `Service` resources of type `LoadBalancer` on EKS. Chart: `aws-load-balancer-controller` 3.6.2 from `https://aws.github.io/eks-charts`.

- **Namespace:** `kube-system`
- **Cloud:** EKS only. GKE uses its built-in ingress; see the [add-ons README](../README.md).
- **Replicas and disruption:** 2 replicas, `maxUnavailable: 1`, preferred anti-affinity across nodes, `system-cluster-critical`.
- **Permissions:** IRSA role created by `environments/aws/addons-iam.tf` using the official controller policy. Argo CD sets the role ARN annotation from the cluster Secret (Terraform output `aws_load_balancer_controller_role_arn`).
- **Required values:** `clusterName`, `region` and `vpcId` must be set explicitly, because nodes require IMDSv2 with a hop limit of 1 and pods cannot read instance metadata. Argo CD supplies them from the cluster Secret; they are not stored in Git.
- **Subnets:** discovered from the `kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb` subnet tags and the shared cluster tag, which the `aws-network` module sets.

Create an ALB with an `Ingress` using `ingressClassName: alb` and annotation `alb.ingress.kubernetes.io/scheme: internet-facing` with `alb.ingress.kubernetes.io/target-type: ip`.
