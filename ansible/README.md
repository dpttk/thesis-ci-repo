# Ansible — host provisioning

Runs after `terraform apply` has created the VM. Regenerate the inventory
from Terraform outputs first, then run the playbook with the GitHub runner
registration data.

## One-off setup

```sh
# 1. Generate inventory.ini from terraform outputs
../scripts/gen-inventory.sh

# 2. Run the playbook. Registration token comes from
#    Settings -> Actions -> Runners -> New self-hosted runner (expires in 1h).
ansible-playbook playbook.yml \
  -e "gha_runner_url=https://github.com/<owner>/thesis-ci-repo" \
  -e "gha_runner_token=<REGISTRATION_TOKEN>"
```

Prefer storing the token via `ansible-vault`:

```sh
ansible-vault create group_vars/runners.yml
# contents:
#   gha_runner_url:   https://github.com/<owner>/thesis-ci-repo
#   gha_runner_token: <REGISTRATION_TOKEN>

ansible-playbook playbook.yml --ask-vault-pass
```

## Roles

| Role | What it installs |
|------|------------------|
| `base` | apt essentials, linux-headers, Go, `yq`, `gh`, `awscli`, `bats` |
| `scanner_host` | `bpfcc-tools`, `libbpfcc`, `apparmor`, `apparmor-utils`, `oci-seccomp-bpf-hook`, bpf mount, AppArmor warmup |
| `gha_runner` | `actions-runner` systemd service running as root with labels `self-hosted,linux,runc-scanner,yc` |
