terraform {
  required_version = ">= 1.6.0"

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.128"
    }
  }
}

provider "yandex" {
  # Authentication via environment: YC_TOKEN (OAuth) or YC_SERVICE_ACCOUNT_KEY_FILE.
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
  zone      = var.yc_zone
}
