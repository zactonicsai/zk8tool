# kubegen user guide

kubegen turns one YAML cluster definition into either

- a **shell script** that creates the cluster with the platform's own CLI, or
- a **Terraform configuration** that creates the same cluster.

kubegen never creates anything itself. It writes files; you review and run them.

| `provider` | Platform                          | Shell script uses        | Terraform uses                       |
|------------|-----------------------------------|--------------------------|--------------------------------------|
| `kind`     | Kubernetes in Docker or Podman    | docker or podman, kind, kubectl | terraform, docker or podman   |
| `aks`      | Azure Kubernetes Service          | az, kubectl              | terraform, az                        |
| `eks`      | Amazon EKS                        | aws, eksctl, kubectl     | terraform, aws                       |
| `vks`      | VMware vSphere Kubernetes Service | kubectl, kubectl-vsphere | terraform, kubectl, kubectl-vsphere  |
| `dks`      | DigitalOcean Kubernetes           | doctl, kubectl           | terraform                            |
| `gks`      | Google Kubernetes Engine (GKE)    | gcloud, kubectl, gke-gcloud-auth-plugin | terraform, gcloud     |

---

## Step 1 - Build kubegen

You need Go 1.22 or newer (<https://go.dev/dl/>).

    ./build.sh

This downloads the one dependency, checks the code and writes `bin/kubegen`.
If Go is missing or too old, the script says so and prints the download link.

Other build commands:

    ./build.sh examples   # build, then regenerate examples/output
    ./build.sh clean      # remove bin/

## Step 2 - Write a cluster definition

Start from the example for your platform:

    cp examples/aks.yaml my-cluster.yaml

Every definition has the same outline:

    apiVersion: kubegen/v1
    provider: aks              # kind | aks | eks | vks | dks | gks
    name: prod-aks
    kubernetesVersion: "1.33"  # always quote versions
    region: eastus             # aks, eks, dks, gks
    tags: {env: prod}
    kubeconfig:
      path: ~/.kube/prod-aks.yaml
    nodePools:                 # aks, eks, vks, dks, gks
      - name: system
        count: 3
        size: Standard_D4s_v5
    aks:                       # settings for the chosen provider
      resourceGroup: rg-prod-aks

`schema/cluster.schema.yaml` documents every field. Editors with the YAML
language server give completion and validation if the file starts with:

    # yaml-language-server: $schema=schema/cluster.schema.yaml

What each platform needs:

| Provider | Required beyond `apiVersion`, `provider`, `name`                                   |
|----------|-------------------------------------------------------------------------------------|
| `kind`   | nothing (set `kind.workerNodes`, `kind.ingressReady`, ... as wanted)                |
| `aks`    | `region`, `nodePools` (each with `size`), `aks.resourceGroup`                       |
| `eks`    | `region`, `nodePools` (each with `size`)                                            |
| `vks`    | `kubernetesVersion`, `nodePools`, `vks.namespace`, `vks.clusterClass`, `vks.vmClass`, `vks.storageClass` |
| `dks`    | `region`, `nodePools` (each with `size`)                                            |
| `gks`    | `region` (a region or a zone), `nodePools` (each with `size`), `gks.project`        |

Node pools are fixed size (`count: 3`) or autoscaled
(`autoscaling: {enabled: true, min: 2, max: 10}`).

## Step 3 - Choose shell or Terraform

| Choose        | When                                                                                   |
|---------------|----------------------------------------------------------------------------------------|
| Shell script  | One-off or throwaway clusters; you want to see the exact CLI commands.                 |
| Terraform     | The cluster will be changed later, torn down cleanly, or managed with other Terraform. |

## Step 4a - Generate and run a shell script

    ./bin/kubegen -f my-cluster.yaml
    # wrote create-prod-aks.sh - run it with: bash create-prod-aks.sh

Read the script, log in to your platform (Step 5), then run it:

    ./create-prod-aks.sh

The script checks its tools, checks that you are logged in, creates the
cluster and node pools, fetches credentials and runs `kubectl get nodes`.

Useful options:

    ./bin/kubegen -f my-cluster.yaml -o -               # print instead of writing a file
    ./bin/kubegen -f my-cluster.yaml -o scripts/up.sh   # choose the file name

## Step 4b - Generate and apply Terraform

    ./bin/kubegen -f my-cluster.yaml -format terraform
    # wrote terraform-prod-aks/main.tf ...

The directory contains:

| File                       | Purpose                                                               |
|----------------------------|-----------------------------------------------------------------------|
| `versions.tf`              | Terraform and provider version requirements                           |
| `main.tf`                  | The resources, with comments explaining each part                     |
| `variables.tf`             | Every setting as a variable; defaults come from your YAML             |
| `outputs.tf`               | Cluster name, endpoint, kubeconfig or the command to fetch it         |
| `terraform.tfvars.example` | Every variable, commented out, with its default and usage hints       |

Then:

    cd terraform-prod-aks
    terraform init
    terraform plan
    terraform apply

To remove the cluster later: `terraform destroy`.

### Customising with tfvars

The generated configuration works as is. To change something without
touching the YAML or the `.tf` files, override variables:

    cp terraform.tfvars.example terraform.tfvars

Uncomment only the settings you want to change, for example a larger system
pool and one more user pool on AKS:

    system_node_pool = {
      name       = "system"
      vm_size    = "Standard_D8s_v5"
      node_count = 3
    }

    user_node_pools = {
      apps = {
        vm_size     = "Standard_D8s_v5"
        autoscaling = { min = 2, max = 10 }
      }
      gpu = {
        vm_size    = "Standard_NC6s_v3"
        node_count = 1
        taints     = ["sku=gpu:NoSchedule"]
      }
    }

For several environments from one configuration, keep one file per
environment and pick it at apply time:

    terraform apply -var-file=staging.tfvars
    terraform apply -var-file=prod.tfvars

(Use a separate Terraform workspace or state per environment so they do not
overwrite each other.)

Running kubegen again overwrites the five generated files but never
`terraform.tfvars` or your own `*.tfvars` files.

## Step 5 - Log in to your platform

Neither output logs in for you.

| Provider | Before running                                                                        |
|----------|---------------------------------------------------------------------------------------|
| `kind`   | Start Docker (or Podman, with `kind.runtime: podman`).                                |
| `aks`    | `az login`. Terraform also needs the subscription: set `aks.subscription` to the subscription ID or export `ARM_SUBSCRIPTION_ID`. |
| `eks`    | `aws configure` or `aws sso login` (set `eks.profile` for a named profile).           |
| `vks`    | `kubectl vsphere login --server <supervisor> --vsphere-username <user>`. The shell script does this itself when `vks.login.method` is `kubectl-vsphere`; Terraform never does. |
| `dks`    | Shell: `doctl auth init`. Terraform: `export DIGITALOCEAN_TOKEN=<token>`.             |
| `gks`    | Shell: `gcloud auth login`. Terraform: `gcloud auth application-default login`. The Kubernetes Engine API must be enabled in the project. |

## Step 6 - Use the cluster

    kubectl get nodes

If you set `kubeconfig.path`, pass it: `kubectl --kubeconfig ~/.kube/prod-aks.yaml get nodes`.
For EKS with Terraform, run the command shown by
`terraform output update_kubeconfig_command` first; for GKE with Terraform,
the one shown by `terraform output get_credentials_command`.

---

## Tool checks

Before writing anything, kubegen checks that the CLIs for your provider and
format are on your PATH. If one is missing it prints the tool, what it is
for and where to download it, writes nothing and exits with code 4:

    error: 2 tool(s) required for provider "aks" (shell) are not installed or not in PATH:
      - az (Azure CLI, creates the AKS cluster)
          install it from: https://learn.microsoft.com/cli/azure/install-azure-cli
      - kubectl (talks to the cluster)
          install it from: https://kubernetes.io/docs/tasks/tools/
    Nothing was written. Install the tools, or pass -skip-tool-check to generate anyway.

Use `-skip-tool-check` when the output will be run somewhere else (CI, a
colleague's machine). Generated shell scripts repeat the check when they
start and exit with code 127 if a tool is missing.

| Tool            | Download                                                                      |
|-----------------|-------------------------------------------------------------------------------|
| docker          | <https://docs.docker.com/get-docker/>                                         |
| podman          | <https://podman.io/docs/installation>                                         |
| kind            | <https://kind.sigs.k8s.io/docs/user/quick-start/#installation>                |
| kubectl         | <https://kubernetes.io/docs/tasks/tools/>                                     |
| az              | <https://learn.microsoft.com/cli/azure/install-azure-cli>                     |
| aws             | <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html> |
| eksctl          | <https://eksctl.io/installation/>                                             |
| doctl           | <https://docs.digitalocean.com/reference/doctl/how-to/install/>               |
| gcloud          | <https://cloud.google.com/sdk/docs/install>                                   |
| gke-gcloud-auth-plugin | <https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl> (after installing gcloud: `gcloud components install gke-gcloud-auth-plugin`) |
| terraform       | <https://developer.hashicorp.com/terraform/install>                           |
| kubectl-vsphere | `https://<your-supervisor-address>/` (CLI tools page served by the Supervisor) |

## Command reference

    kubegen -f cluster.yaml [-format shell|terraform] [-o path] [-skip-tool-check]

| Flag               | Meaning                                                                         |
|--------------------|---------------------------------------------------------------------------------|
| `-f`               | Cluster definition file (required)                                              |
| `-format`          | `shell` (default) or `terraform`                                                |
| `-o`               | Shell: script path, `-` for stdout (default `create-<name>.sh`). Terraform: directory (default `terraform-<name>`) |
| `-skip-tool-check` | Generate even when required CLIs are missing                                    |

| Exit code | Meaning                                  |
|-----------|------------------------------------------|
| 0         | Files written                            |
| 2         | Wrong command-line usage                 |
| 3         | Cluster definition is invalid            |
| 4         | Required tools are missing               |

## Examples

`examples/` holds one definition per provider. `examples/output/` holds what
kubegen generates from them, so you can see the result before installing
anything:

    examples/output/shell/create-<name>.sh        shell scripts
    examples/output/terraform/<provider>/         Terraform, including terraform.tfvars.example
    examples/output/console.txt                   what kubegen printed

Regenerate them with `./build.sh examples`.

## Using Podman

- **kind on Podman:** set `kind.runtime: podman` in the definition. kubegen
  then checks for `podman` instead of `docker` and the script tells kind to
  use it. Example: `podman/kind-podman.yaml`.
- **kubegen without Go:** `podman/kubegen.sh -f my-cluster.yaml` builds and
  runs kubegen in a container.

Details and rootless caveats: [podman/README.md](../podman/README.md).

## Differences between the two outputs

- **AKS:** Terraform cannot taint the system (first) pool, and `aks.attachACR`
  must be the registry's full resource ID. Without `aks.sshPublicKeyPath`
  Terraform configures no SSH access (the shell script lets `az` generate a key).
- **EKS:** the shell script uses eksctl, which builds the VPC through
  CloudFormation. Terraform creates the VPC, subnets, NAT, IAM roles and node
  groups as plain resources. Do not mix the two for the same cluster.
- **VKS:** Terraform applies the Cluster object through the `alekc/kubectl`
  provider and uses local `kubectl` commands to wait and fetch the kubeconfig.
- **DKS:** the first node pool is part of the cluster resource in Terraform;
  changing its name or size replaces the cluster.
- **kind:** `kind.waitTimeout` only applies to the shell script.
- **GKE:** both outputs create the cluster with a one-node `default-pool`
  and then remove it, so that every pool has the name and settings from
  your definition. `gks.deletionProtection` only affects Terraform.

## Google Kubernetes Engine (`gks`) notes

    provider: gks
    region: us-central1          # region = regional cluster, zone = zonal cluster
    nodePools:
      - name: general
        count: 1                 # per zone in a regional cluster
        size: e2-standard-4
    gks:
      project: my-gcp-project

- **Counts are per zone.** A regional cluster spreads each pool over the
  region's zones (usually three), so `count: 1` gives three nodes and
  `autoscaling: {min: 1, max: 4}` means 3 to 12. Set `region` to a zone such
  as `us-central1-a`, or list `zones` on a pool, to limit this.
- **`default-pool` is reserved** as a pool name.
- **`tags` become Google labels:** lowercase letters, digits, `-` and `_`
  only. kubegen rejects anything else.
- **`gke-gcloud-auth-plugin`** is required for kubectl to log in to GKE.
- **`privateNodes: true`** removes the nodes' public IPs; they need Cloud NAT
  to pull images from the internet. kubegen does not create the NAT.
- Full example: `examples/gks.yaml`.

## Troubleshooting

| Message                                             | Fix                                                               |
|-----------------------------------------------------|-------------------------------------------------------------------|
| `field xyz not found in type main.Config`           | A key is misspelled or misplaced; compare with the schema.         |
| `kubernetesVersion: kind needs a full patch version`| Use e.g. `"1.33.1"`, or set `kind.nodeImage`.                      |
| `not logged in to Azure; run: az login`             | Log in (Step 5) and run the script again.                          |
| `AKS pool names are 1-12 lowercase letters/digits`  | Rename the pool, e.g. `apps1` instead of `apps-1`.                 |
| Terraform: `subscription_id is a required provider property` | Set `aks.subscription` or export `ARM_SUBSCRIPTION_ID`.   |
| `not logged in to Google Cloud; run: gcloud auth login` | Log in, then run the script again. For Terraform use `gcloud auth application-default login`. |
| GKE: far more nodes than expected | Counts are per zone in a regional cluster; see the GKE notes. |
| VKS: cluster class, VM class or version not found   | Use the values from `kubectl get clusterclass -A`, `kubectl get vmclass`, `kubectl get kr`. |
