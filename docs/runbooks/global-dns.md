# Global DNS

Sets up DNS and cross-cloud traffic steering: a Route 53 parent zone, a Cloud DNS subdomain delegated from it, and weighted or failover records for the application. Everything is off until a domain is supplied.

## Cost

Figures are approximate; check current AWS and Google Cloud pricing before applying.

- Route 53 hosted zone: about $0.50 per month.
- Route 53 health checks: about $0.50 to $0.75 per month each, plus about $1.00 each for HTTPS and for the 10 second interval. Two HTTPS checks cost a few dollars per month.
- Cloud DNS zone: about $0.20 per month.
- Queries: about $0.40 to $0.60 per million. Negligible here.
- Domain registration: roughly $10-15 per year for common domains, billed by the registrar.

If you do not need a zone, leave `domain_name` and `dns_name` empty and nothing is created.

## Prerequisites

- A registered domain. It can be registered through Route 53 (console or `aws route53domains`), or at any registrar.
- The AWS and GCP stacks working as described in the [network](aws-network.md) and [GKE](gcp-gke.md) runbooks (the network and clusters do not have to exist yet to create the zones).
- The Cloud DNS API enabled in the GCP project:

  ```bash
  gcloud services enable dns.googleapis.com --project <PROJECT_ID>
  ```

- Permissions to manage Route 53 hosted zones, records and health checks, and Cloud DNS zones.

## Apply order

The two stacks never read each other's state. The GCP name servers are copied from one stack's output into the other's input, so the order matters the first time.

### 1. GCP: create the delegated subdomain zone

```bash
cd infra/terraform/environments/gcp
terraform plan -var environment=dev -var project_id=<PROJECT_ID> -var dns_name=gke.example.com -out=tfplan
terraform apply tfplan
terraform output dns_name_servers
```

Keep the other variables the same as in your earlier applies (for example `master_authorized_cidrs`), so the plan shows only the DNS zone as new. Copy the four name servers, for example `ns-cloud-a1.googledomains.com.`.

### 2. AWS: create the parent zone and delegate the subdomain

```bash
cd infra/terraform/environments/aws
terraform plan -var environment=dev -var domain_name=example.com \
  -var 'delegated_subdomains={gke=["ns-cloud-a1.googledomains.com.","ns-cloud-a2.googledomains.com.","ns-cloud-a3.googledomains.com.","ns-cloud-a4.googledomains.com."]}' \
  -out=tfplan
terraform apply tfplan
terraform output dns_name_servers
```

Expect a hosted zone and one NS record. Keep these values in a local `terraform.tfvars` (ignored by Git) so later applies do not drop them.

### 3. Delegate the domain from the registrar to Route 53

Set the domain's name servers to the four values from `dns_name_servers` (step 2):

- **Registered in Route 53:** in the console, open the registered domain and choose **Add or edit name servers**, or run `aws route53domains update-domain-nameservers --region us-east-1 --domain-name example.com --nameservers Name=<NS1> Name=<NS2> Name=<NS3> Name=<NS4>`. Domains registered in Route 53 start with name servers of an automatically created zone, which will differ from this stack's zone.
- **Registered elsewhere:** in the registrar's DNS settings, replace the name servers with the Route 53 ones. Remove the trailing dots if the registrar requires.

Propagation can take minutes to a day, depending on the registrar and the TTL of the old name servers.

### 4. Add endpoints when the load balancers exist

Once the AWS load balancer has a host name and the GCP load balancer has an address, add an A record `lb.gke.example.com` in the Cloud DNS zone (using a host name for the GCP endpoint keeps both endpoints the same kind), then apply the AWS stack with the endpoints:

```bash
terraform plan -var environment=dev -var domain_name=example.com \
  -var 'dns_endpoints={aws={fqdn="<ALB_HOSTNAME>"},gcp={fqdn="lb.gke.example.com"}}' \
  -var routing_policy=weighted \
  -out=tfplan
```

Use `-var routing_policy=failover -var primary_cloud=aws` for disaster recovery mode. Each endpoint accepts `port`, `protocol`, `path`, `failure_threshold` and `request_interval`.

## Verify

```bash
dig NS example.com +short                       # Route 53 name servers
dig NS gke.example.com +short                   # Cloud DNS name servers (after delegation)
dig +short app.example.com                      # resolves to one cloud's answer
for i in $(seq 1 10); do dig +short app.example.com @<ROUTE53_NS>; done   # weighted answers vary
dig +trace app.example.com                      # follow the delegation from the root
aws route53 get-health-check-status --health-check-id "$(terraform output -json dns_health_check_ids | jq -r .aws)"
```

For a failover test, make the primary's health endpoint fail (or temporarily point its health check at a closed port), wait for the health check to turn unhealthy (about 90 seconds at the defaults) plus the record TTL, then confirm `app.example.com` resolves to the secondary. Restore the primary and confirm it returns. Resolvers may cache longer than the TTL, so test against the authoritative name servers when measuring.

## Change the traffic split

Change `dns_weights` (for example `{aws=90, gcp=10}`) or `routing_policy` and apply. A weight of 0 drains a cloud. Changes take effect as resolver caches expire, which is at least the record TTL (60 seconds by default).

## Destroy

1. If you want to keep the domain but stop recurring costs, remove the records and health checks first by applying with `dns_endpoints={}`.
2. Destroy the zones:

   - AWS: set `domain_name` back to empty (or run `terraform destroy`) in `environments/aws`. Delegation NS records and the hosted zone are removed.
   - GCP: set `dns_name` back to empty (or destroy) in `environments/gcp`. If the zone holds record sets Terraform does not manage, set `dns_force_destroy=true` and apply before destroying.

3. At the registrar, change the name servers away from the deleted Route 53 zone, or the domain will fail to resolve.

## Destroy checklist

- [ ] Route 53 health checks (`aws route53 list-health-checks`)
- [ ] Route 53 records for `app.<domain>` and the delegation NS records (`aws route53 list-resource-record-sets --hosted-zone-id <ID>`)
- [ ] Route 53 hosted zone (`aws route53 list-hosted-zones`)
- [ ] Cloud DNS record sets and zone (`gcloud dns managed-zones list`, `gcloud dns record-sets list --zone <ZONE>`)
- [ ] Registrar name servers updated, or the domain registration cancelled or left intentionally pointing elsewhere
- [ ] If DNSSEC was enabled, the DS record removed from the parent zone before the Cloud DNS zone is deleted

## Troubleshooting

- **`dig NS gke.example.com` returns nothing:** the registrar delegation to Route 53 is not live yet, or the NS record is missing; check `dig NS example.com` first.
- **`SERVFAIL` after enabling DNSSEC:** the DS record is missing or wrong at the parent zone. Remove it and disable DNSSEC, or add the correct DS record.
- **Health check stays unhealthy:** check that the endpoint answers `GET <path>` over the configured protocol and port with a 2xx or 3xx status, and that firewalls or security groups allow Route 53 health checker addresses.
- **A CNAME and A conflict error:** both endpoints must be the same kind. Publish a host name for the endpoint that only has an IP.
