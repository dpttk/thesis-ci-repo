variable "env" {
  description = "Environment label (e.g. staging, prod); used in resource names and labels."
  type        = string
  default     = "prod"
}

variable "yc_cloud_id" {
  description = "Yandex Cloud cloud_id"
  type        = string
}

variable "yc_folder_id" {
  description = "Yandex Cloud folder_id"
  type        = string
}

variable "yc_zone" {
  description = "Availability zone for the runner VM"
  type        = string
  default     = "ru-central1-a"
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH into the runner (set to your admin IP/24)."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_public_key" {
  description = "Contents of the SSH public key installed on the runner for the 'ubuntu' user."
  type        = string
}

variable "runner_machine" {
  description = "Compute platform/cores/memory for the runner VM."
  type = object({
    platform_id = string
    cores       = number
    memory      = number
    disk_gb     = number
  })
  default = {
    platform_id = "standard-v3"
    cores       = 2
    memory      = 8
    disk_gb     = 40
  }
}

variable "runner_image_family" {
  description = "Image family for the runner boot disk. ubuntu-2204-lts is the tested baseline."
  type        = string
  default     = "ubuntu-2204-lts"
}

variable "artifacts_bucket_name" {
  description = "Name of the Yandex Object Storage bucket for scan artifacts (must be globally unique in YC)."
  type        = string
}
