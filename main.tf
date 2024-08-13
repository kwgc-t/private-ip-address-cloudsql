
# VPC
resource "google_compute_network" "private_access_vpc" {
  project                  = var.project_id
  name                     = "private-access-vpc"
  auto_create_subnetworks  = "false"
  enable_ula_internal_ipv6 = false
}

resource "google_vpc_access_connector" "private_access_connector" {
  project        = var.project_id
  name           = "private-access-connector"
  ip_cidr_range  = "10.0.0.0/28"
  network        = google_compute_network.private_access_vpc.name
  region         = var.region
  machine_type   = "f1-micro"
  max_instances  = 10
  min_instances  = 2
  max_throughput = 1000
}

resource "google_compute_global_address" "private_access_db_peering_ip" {
  project       = var.project_id
  name          = "private-access-private-ip-alloc"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.private_access_vpc.id
}

resource "google_service_networking_connection" "private_connection" {
  network                 = google_compute_network.private_access_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_access_db_peering_ip.name]
}

resource "google_compute_firewall" "private_access_vpc_fw" {
  project = var.project_id
  name    = "private-access-serverless-vpc-connect-rule"
  network = google_compute_network.private_access_vpc.name

  allow {
    protocol = "tcp"
  }
  priority  = "1000"
  direction = "INGRESS"

  source_ranges = ["35.199.224.0/19"]
}

resource "google_compute_subnetwork" "private_access_db_bastion" {
  project                  = var.project_id
  private_ip_google_access = true
  name                     = "private-access-db-bastion"
  ip_cidr_range            = "10.0.0.16/28"
  region                   = var.region
  network                  = google_compute_network.private_access_vpc.id
}

resource "google_compute_firewall" "private_access_vpc_bastion_fw" {
  project = var.project_id
  name    = "private-access-bastion-rule"
  network = google_compute_network.private_access_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  priority  = "1000"
  direction = "INGRESS"

  source_ranges = ["35.235.240.0/20"]
}

# Cloud SQL
resource "google_sql_database_instance" "private_access_db" {
  project          = var.project_id
  name             = "private-access-db"
  region           = var.region
  database_version = "POSTGRES_15"
  root_password    = "abcABC123!"

  settings {
    tier = "db-f1-micro"
    ip_configuration {
      private_network                               = google_compute_network.private_access_vpc.self_link
      ipv4_enabled                                  = false
      enable_private_path_for_google_cloud_services = true
    }
  }
  deletion_protection = false

  depends_on = [
    google_service_networking_connection.private_connection
  ]
}

# Cloud NAT

resource "google_compute_router" "private_access_router" {
  name    = "private-access-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.private_access_vpc.self_link
}

# resource "google_compute_address" "private_access_address" {
#   name    = "private_access-address"
#   project = var.project_id
#   region  = var.region
# }

resource "google_compute_router_nat" "private_access_nat" {
  name                               = "private-access-nat"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.private_access_router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}



# Compute Engine(踏み台サーバー)

resource "google_service_account" "private_access_bastion_sa" {
  project      = var.project_id
  account_id   = "private-access-bastion-sa"
  display_name = "private-access-bastion-sa"
  description  = "dbの踏み台サーバーにアタッチするサービスアカウント"
}

resource "google_compute_instance" "bastion_vm" {
  project      = var.project_id
  name         = "private-access-db-bastion"
  machine_type = "e2-micro"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-12-bookworm-v20240213"

    }
  }

  network_interface {
    network    = google_compute_network.private_access_vpc.id
    subnetwork = google_compute_subnetwork.private_access_db_bastion.id
  }

  metadata_startup_script = <<-EOF
#! /bin/bash
sudo apt update -y
sudo apt install -y wget
sudo wget https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.0.0/cloud-sql-proxy.linux.amd64 -O /usr/bin/cloud-sql-proxy
sudo chmod +x /usr/bin/cloud-sql-proxy
sudo apt install -y postgresql-client
  EOF


  service_account {
    email  = google_service_account.private_access_bastion_sa.email
    scopes = ["cloud-platform"]
  }

  depends_on = [
    google_compute_router_nat.private_access_nat
  ]
}

# IAMロール
resource "google_project_iam_binding" "sql_instance_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"

  members = [
    format("%s:%s", "serviceAccount", google_service_account.private_access_bastion_sa.email),
  ]
}

resource "google_project_iam_binding" "iap_tunnel_resource_accessor" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"

  members = [
    format("%s:%s", "user", var.your_account),
  ]
}

resource "google_project_iam_binding" "compute_instance_admin_v1" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"

  members = [
    format("%s:%s", "user", var.your_account),
  ]
}
