# aws-load-balancer-controller

Provisions ALBs for `Ingress` resources (class `alb`) and NLBs for `Service` resources of type `LoadBalancer` on EKS. Chart: `aws-load-balancer-controller` 3.6.2 from `https://aws.github.io/eks-charts`.

- **Namespace:** `kube-system`
- **Cloud:** EKS only. GKE uses its built-in ingress; see the [add-ons README](../README.md).
- **Replicas and disruption:** 2 replicas, `maxUnavailable: 1`, preferred anti-affinity across nodes, `system-cluster-critical`.
- **Permissions:** IRSA role created by `environments/aws/addons-iam.tf` using the official controller policy. Set the role ARN in `values-aws.yaml` from the `aws_load_balancer_controller_role_arn` output.
- **Required values:** `clusterName`, `region` and `vpcId` are set explicitly in `values-aws.yaml`, because nodes require IMDSv2 with a hop limit of 1 and pods cannot read instance metadata.
- **Subnets:** discovered from the `kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb` subnet tags and the shared cluster tag, which the `aws-network` module sets.

Create an ALB with an `Ingress` using `ingressClassName: alb` and annotation `alb.ingress.kubernetes.io/scheme: internet-facing` with `alb.ingress.kubernetes.io/target-type: ip`.
