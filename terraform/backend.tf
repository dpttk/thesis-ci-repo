terraform {
  backend "s3" {
    # Values are wired at `terraform init -backend-config=...` time or via
    # ENV vars so they can come from GitHub Secrets. See README.
    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }
    region = "ru-central1"
    # bucket, key set via -backend-config
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
