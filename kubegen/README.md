# kubegen

Reads a cluster definition YAML and writes a shell script that creates the
cluster with the provider's own CLI.

| provider | platform                          | CLIs used                 |
|----------|-----------------------------------|---------------------------|
| `kind`   | Kubernetes in Docker (local)      | docker, kind, kubectl     |
| `aks`    | Azure Kubernetes Service          | az, kubectl               |
| `eks`    | Amazon EKS                        | aws, eksctl, kubectl      |
| `vks`    | VMware vSphere Kubernetes Service | kubectl, kubectl-vsphere  |
| `dks`    | DigitalOcean Kubernetes           | doctl, kubectl            |

Step-by-step instructions: [docs/USER_GUIDE.md](docs/USER_GUIDE.md).

## Build

    ./build.sh             # needs Go 1.22+; writes bin/kubegen

## Use

    ./bin/kubegen -f examples/aks.yaml                     # writes create-prod-aks.sh
    ./bin/kubegen -f examples/aks.yaml -o -                # print the script instead
    ./bin/kubegen -f examples/aks.yaml -format terraform   # writes terraform-prod-aks/

kubegen only writes files; nothing is created until you run the script or
`terraform apply`.

The Terraform directory holds commented `.tf` files whose variable defaults
come from the YAML, plus `terraform.tfvars.example` listing every variable
you can override.

Before writing anything kubegen checks that the provider's CLIs are on
PATH. If any are missing it prints each one with its download link and exits
with code 4. Pass `-skip-tool-check` to generate anyway (for example when the
script will run on another machine); the script repeats the same check when
it starts and exits 127 if a tool is missing.

Exit codes: 2 usage, 3 invalid cluster definition, 4 missing tools.

## Files

- `schema/cluster.schema.yaml` - the schema (JSON Schema written in YAML),
  with every field documented. Point your editor's YAML language server at it
  for completion and validation.
- `examples/` - one definition per provider; `examples/output/` holds the
  scripts and Terraform generated from them.
- `templates/` - the Terraform for each provider (embedded in the binary).
- `terraform.go` - Terraform variables and file generation.
- `validate.go` - the same rules enforced by the program.
- `generate.go` - command generation, one function per provider.
- `tools.go` - required CLIs and their download links.

## Notes

- Authentication is not handled: log in first (`az login`, `aws configure`,
  `doctl auth init`). The script checks and stops with a hint if you are not.
- vks: the script applies a Cluster API `Cluster` manifest to your vSphere
  Namespace. `clusterClass`, `vmClass`, `storageClass` and
  `kubernetesVersion` must match what your Supervisor offers
  (`kubectl get clusterclass -A`, `kubectl get vmclass`, `kubectl get kr`).
- eks: autoscaling sets node group min/max only; install Cluster Autoscaler
  or Karpenter to act on them.
