# thesis-ci-repo

CI for the testing security profile generator in my fork of runc. This repository lives next to the
[runc-fork](https://github.com/dpttk/runc). It holds environment for thesis, that is _not_ the
runtime itself:

- **Infrastructure**: Terraform code for a dedicated self-hosted runner VM in
  Yandex Cloud plus an Object Storage bucket for scan artifacts.
- **Host provisioning**: Ansible playbook that installs the BCC toolchain,
  `oci-seccomp-bpf-hook`, AppArmor utilities, and the GitHub Actions runner.
- **OCI bundles**: a directory per scenario (`bundles/<name>/bundle.yaml`) that
  describes the root filesystem recipe, `config.json` overrides, scan flags,
  bats test packs, and the validation contract for the generated profiles.
- **Scripts**: `fetch-runc.sh`, `prepare-bundle.sh`, `run-scan.sh`,
  `verify-profiles.sh`, `upload-artifacts.sh`, `gen-inventory.sh`.
- **Workflow**: `scan-matrix.yml` — the only CI job. Triggered by
  `repository_dispatch` from the runc-fork build workflow, plus nightly and
  manual dispatch. Terraform/Ansible are applied manually from a workstation,
  not from GitHub Actions.

## End-to-end flow

```
runc-fork              thesis-ci-repo                     Yandex Cloud
---------              --------------                     ------------
push/tag               repository_dispatch
   |                   runc-build-available
   v                          |
publish-runc-binary.yml       v
  build + SHA256SUMS    scan-matrix.yml
  upload artifact   -->   fetch-runc.sh (gh run download)
                          prepare-bundle.sh
                          run-scan.sh (runc --security-scan)
                          verify-profiles.sh + bats
                          upload-artifacts.sh ----------> s3://runc-ci-artifacts/
                          aggregate -> Job Summary
```

## Layout

```
.github/workflows/
  scan-matrix.yml
ansible/
  playbook.yml
  inventory.ini.tpl
  roles/{base,scanner_host,gha_runner}/
terraform/
  main.tf variables.tf outputs.tf versions.tf backend.tf
bundles/
  busybox-default/{bundle.yaml, tests/}
  juice-shop/{bundle.yaml, tests/}
  templates/minimal.config.json
scripts/
  fetch-runc.sh prepare-bundle.sh run-scan.sh
  verify-profiles.sh upload-artifacts.sh gen-inventory.sh
  make-summary.sh
```

## Adding a new bundle

1. `mkdir bundles/<name>` and write `bundle.yaml` (see
   [bundles/busybox-default/bundle.yaml](bundles/busybox-default/bundle.yaml)
   for the shape and [scripts/prepare-bundle.sh](scripts/prepare-bundle.sh)
   for the rootfs recipes that are currently supported:
   `busybox-tar | docker-export | tar-url | script`).
2. Drop any bundle-specific bats files in `bundles/<name>/tests/`.
3. Commit. The `discover` job in `scan-matrix.yml` picks the new directory
   up automatically.

## Infrastructure lifecycle — manual only

Terraform and Ansible are **not** wired into GitHub Actions; the cloud
resources and the runner host are provisioned by hand (rare one-off work).

```sh
# 1. Provision the YC resources (VPC, SG, SA, bucket, VM)
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in values
terraform init \
  -backend-config="bucket=<state-bucket>" \
  -backend-config="key=tfstate/runc-ci.tfstate" \
  -backend-config="access_key=$YC_STORAGE_ACCESS_KEY" \
  -backend-config="secret_key=$YC_STORAGE_SECRET_KEY"
terraform apply

# 2. Generate the Ansible inventory from terraform outputs
cd ..
scripts/gen-inventory.sh

# 3. Install the scanner host + register the self-hosted runner
cd ansible
ansible-playbook playbook.yml \
  -e "gha_runner_url=https://github.com/<owner>/thesis-ci-repo" \
  -e "gha_runner_token=<REGISTRATION_TOKEN>"
```

See [ansible/README.md](ansible/README.md) for the ansible-vault flow.

## Required secrets / variables (GitHub Actions)

In `thesis-ci-repo` (consumed by `scan-matrix.yml`):

| Secret / Variable | Purpose |
|-------------------|---------|
| `RUNC_ARTIFACTS_TOKEN` (secret) | PAT with `actions: read` on the runc-fork repo; used by `fetch-runc.sh`. |
| `RUNC_FORK_REPO` (variable) | `<owner>/<repo>` of the runc-fork (used for the nightly schedule trigger). |
| `YC_STORAGE_ACCESS_KEY` / `YC_STORAGE_SECRET_KEY` (secrets) | S3-compatible credentials for `aws s3 cp` from the runner to the artifacts bucket. |
| `YC_ARTIFACTS_BUCKET` (variable) | Object Storage bucket name for scan artifacts. |

In `runc-fork`:

| Secret / Variable | Purpose |
|-------------------|---------|
| `CI_REPO_DISPATCH_TOKEN` (secret) | Fine-grained PAT with `repository_dispatch: write` on this repo. |
| `CI_REPO` (variable) | `<owner>/<repo>` of this repository. |

Terraform and the GitHub runner registration token are handled off-CI (local
shell / ansible-vault) — see the block above.

## Status

Initial scaffold. See [scripts/](scripts) and
[bundles/busybox-default/](bundles/busybox-default) for the first working
path. Terraform/Ansible land incrementally; see commit history.
