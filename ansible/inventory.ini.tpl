[runners]
runner ansible_host=@@RUNNER_IP@@ ansible_user=ubuntu ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'

[runners:vars]
artifacts_bucket=@@ARTIFACTS_BUCKET@@
