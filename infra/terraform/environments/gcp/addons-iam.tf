# Google service accounts for the cluster add-ons, bound to Kubernetes service accounts through Workload
# Identity. The service account emails are outputs to paste into the add-on values files under
# platform/addons. Nothing here installs the add-ons.
#
# Permissions are as tight as Cloud DNS allows: roles/dns.admin is granted on the one managed zone only,
# plus roles/dns.reader at project level, because listing zones is a project-level operation.

locals {
  addons_member_prefix = "serviceAccount:${module.gke.workload_pool}"
}

# --- external-dns ---

resource "google_service_account" "external_dns" {
  count = var.enable_external_dns_iam ? 1 : 0

  project      = var.project_id
  account_id   = "extdns-${var.environment}"
  display_name = "external-dns on ${local.cluster_name}"
}

resource "google_service_account_iam_member" "external_dns_workload_identity" {
  count = var.enable_external_dns_iam ? 1 : 0

  service_account_id = google_service_account.external_dns[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.addons_member_prefix}[external-dns/external-dns]"

  # The workload pool exists only once the cluster does.
  depends_on = [module.gke]
}

resource "google_dns_managed_zone_iam_member" "external_dns_zone" {
  count = var.enable_external_dns_iam ? 1 : 0

  project      = var.project_id
  managed_zone = module.dns.zone_name
  role         = "roles/dns.admin"
  member       = "serviceAccount:${google_service_account.external_dns[0].email}"
}

resource "google_project_iam_member" "external_dns_reader" {
  count = var.enable_external_dns_iam ? 1 : 0

  project = var.project_id
  role    = "roles/dns.reader"
  member  = "serviceAccount:${google_service_account.external_dns[0].email}"
}

# --- cert-manager (Cloud DNS DNS-01) ---

resource "google_service_account" "cert_manager" {
  count = var.enable_cert_manager_iam ? 1 : 0

  project      = var.project_id
  account_id   = "certmgr-${var.environment}"
  display_name = "cert-manager on ${local.cluster_name}"
}

resource "google_service_account_iam_member" "cert_manager_workload_identity" {
  count = var.enable_cert_manager_iam ? 1 : 0

  service_account_id = google_service_account.cert_manager[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.addons_member_prefix}[cert-manager/cert-manager]"

  depends_on = [module.gke]
}

resource "google_dns_managed_zone_iam_member" "cert_manager_zone" {
  count = var.enable_cert_manager_iam ? 1 : 0

  project      = var.project_id
  managed_zone = module.dns.zone_name
  role         = "roles/dns.admin"
  member       = "serviceAccount:${google_service_account.cert_manager[0].email}"
}

resource "google_project_iam_member" "cert_manager_reader" {
  count = var.enable_cert_manager_iam ? 1 : 0

  project = var.project_id
  role    = "roles/dns.reader"
  member  = "serviceAccount:${google_service_account.cert_manager[0].email}"
}
