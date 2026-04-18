output "runner_public_ip" {
  description = "Public IP (NAT) of the runner VM; used by Ansible inventory."
  value       = yandex_compute_instance.runner.network_interface[0].nat_ip_address
}

output "runner_private_ip" {
  description = "Private IP of the runner in the CI subnet."
  value       = yandex_compute_instance.runner.network_interface[0].ip_address
}

output "runner_instance_id" {
  description = "Compute instance id"
  value       = yandex_compute_instance.runner.id
}

output "runner_sa_id" {
  description = "Service account id attached to the runner"
  value       = yandex_iam_service_account.runner.id
}

output "artifacts_bucket" {
  description = "Object Storage bucket name for scan artifacts"
  value       = yandex_storage_bucket.artifacts.bucket
}
