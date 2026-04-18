locals {
  common_labels = {
    project = "runc-ci"
    env     = var.env
    managed = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

resource "yandex_vpc_network" "runc_ci" {
  name        = "runc-ci-${var.env}"
  description = "Network for the runc-fork CI self-hosted runner"
  labels      = local.common_labels
}

resource "yandex_vpc_subnet" "runc_ci" {
  name           = "runc-ci-${var.env}-${var.yc_zone}"
  description    = "Subnet for the runner VM"
  v4_cidr_blocks = ["10.42.0.0/24"]
  zone           = var.yc_zone
  network_id     = yandex_vpc_network.runc_ci.id
  labels         = local.common_labels
}

resource "yandex_vpc_security_group" "runc_ci_runner" {
  name        = "runc-ci-${var.env}-runner"
  description = "SSH-in from admin CIDR, all egress"
  network_id  = yandex_vpc_network.runc_ci.id
  labels      = local.common_labels

  ingress {
    description    = "ssh admin"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = [var.admin_cidr]
  }

  egress {
    description    = "any"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# -----------------------------------------------------------------------------
# IAM + Object Storage bucket
# -----------------------------------------------------------------------------

resource "yandex_iam_service_account" "runner" {
  name        = "runc-ci-${var.env}-runner"
  description = "SA assumed by the self-hosted runner for Object Storage uploads"
}

resource "yandex_resourcemanager_folder_iam_member" "runner_storage_editor" {
  folder_id = var.yc_folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.runner.id}"
}

resource "yandex_storage_bucket" "artifacts" {
  bucket   = var.artifacts_bucket_name
  max_size = 10 * 1024 * 1024 * 1024 # 10 GiB
  labels   = local.common_labels

  anonymous_access_flags {
    read        = false
    list        = false
    config_read = false
  }
}

# -----------------------------------------------------------------------------
# Runner compute instance
# -----------------------------------------------------------------------------

data "yandex_compute_image" "boot" {
  family = var.runner_image_family
}

resource "yandex_compute_instance" "runner" {
  name        = "runc-ci-${var.env}-runner"
  description = "Self-hosted GitHub Actions runner for runc-fork security-scan matrix"
  hostname    = "runc-ci-runner"
  zone        = var.yc_zone
  labels      = local.common_labels

  platform_id        = var.runner_machine.platform_id
  service_account_id = yandex_iam_service_account.runner.id

  resources {
    cores         = var.runner_machine.cores
    memory        = var.runner_machine.memory
    core_fraction = 100
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.boot.id
      size     = var.runner_machine.disk_gb
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.runc_ci.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.runc_ci_runner.id]
  }

  metadata = {
    ssh-keys           = "ubuntu:${var.ssh_public_key}"
    user-data          = <<-EOT
      #cloud-config
      hostname: runc-ci-runner
      preserve_hostname: false
      package_update: true
      package_upgrade: true
    EOT
    serial-port-enable = 1
  }

  scheduling_policy {
    preemptible = false
  }
}
