# kubegen with Podman - user guide

This guide covers one path only: a local Kubernetes cluster built with
**kind running on Podman**, with no Docker involved. Podman can also build
and run kubegen itself, so Go is optional.

For cloud platforms (AKS, EKS, VKS, DigitalOcean) and Docker-based kind, see
[USER_GUIDE.md](USER_GUIDE.md).

What you end up with:

    your-cluster.yaml  -->  kubegen  -->  create-<name>.sh  -->  kind cluster in Podman containers

---

## Step 1 - Install the tools

| Tool      | Needed for                         | Download                                                       |
|-----------|------------------------------------|----------------------------------------------------------------|
| podman    | runs the cluster nodes             | <https://podman.io/docs/installation>                          |
| kind      | creates the cluster                | <https://kind.sigs.k8s.io/docs/user/quick-start/#installation> |
| kubectl   | talks to the cluster               | <https://kubernetes.io/docs/tasks/tools/>                      |
| go 1.22+  | building kubegen (optional, Step 3)| <https://go.dev/dl/>                                           |
| terraform | Terraform output only (Step 7)     | <https://developer.hashicorp.com/terraform/install>            |

Check them:

    podman --version
    kind --version
    kubectl version --client

You do not have to remember this list: kubegen checks for the tools and
prints the download link for any that are missing (see Step 5).

## Step 2 - Prepare Podman

### Linux

Podman runs rootless by default. kind needs two things for that:

1. cgroup v2. Check with:

       podman info --format '{{.Host.CgroupsVersion}}'     # should print v2

2. CPU delegation for your user session. Create
   `/etc/systemd/system/user@.service.d/delegate.conf` containing

       [Service]
       Delegate=yes

   then run `sudo systemctl daemon-reload` and log out and back in.

kind's own rootless guide has the full details and distro-specific notes:
<https://kind.sigs.k8s.io/docs/user/rootless/>

### macOS and Windows

Podman runs containers in a small Linux VM called a machine. Create one with
enough room for a multi-node cluster, then start it:

    podman machine init --cpus 4 --memory 8192
    podman machine start

Start the machine again after every reboot (`podman machine start`).

### Check

    podman info

If this prints system information without an error, Podman is ready.

## Step 3 - Get kubegen

Pick one.

**Option A - build with Go**

    ./build.sh
    ./bin/kubegen -h

**Option B - no Go: run kubegen in a Podman container**

    podman/kubegen.sh -h

The first run builds a small image from `podman/Containerfile`; later runs
reuse it. Wherever this guide says `./bin/kubegen`, use `podman/kubegen.sh`
instead. Two differences:

- Run it from the project root and use relative paths for `-f` and `-o`
  (the current directory is what the container can see).
- It skips kubegen's tool check, because the container holds only kubegen.
  The generated script still checks for its tools when you run it.

## Step 4 - Write the cluster definition

Start from the example:

    cp podman/kind-podman.yaml my-cluster.yaml

It looks like this:

    apiVersion: kubegen/v1
    provider: kind
    name: dev-podman
    kubernetesVersion: "1.33.1"   # full patch version, in quotes

    kind:
      runtime: podman             # this line selects Podman
      controlPlaneNodes: 1
      workerNodes: 2
      extraPortMappings:
        - containerPort: 30080    # a NodePort inside the cluster ...
          hostPort: 8080          # ... reachable on localhost:8080

Settings you can use under `kind:`

| Setting             | Meaning                                                          |
|---------------------|------------------------------------------------------------------|
| `runtime`           | `podman` (required for this guide) or `docker`                   |
| `controlPlaneNodes` | Number of control-plane nodes (default 1)                        |
| `workerNodes`       | Number of worker nodes (default 0)                               |
| `nodeImage`         | Exact node image; overrides `kubernetesVersion`                  |
| `extraPortMappings` | Host ports forwarded to the first control-plane node             |
| `ingressReady`      | Publishes host ports 80 and 443 - see the warning below          |
| `podSubnet`, `serviceSubnet` | Cluster network ranges                                  |
| `apiServerAddress`, `apiServerPort` | Where the API server listens on the host         |
| `disableDefaultCNI` | Skip kind's network plugin to install your own                   |
| `waitTimeout`       | How long to wait for the control plane (default `120s`)          |

> **Ports below 1024.** Rootless Podman cannot publish host ports below
> 1024, so `ingressReady: true` (ports 80 and 443) fails. Use
> `extraPortMappings` with high host ports such as 8080 and 8443, as the
> example does.

`schema/cluster.schema.yaml` documents every field.

## Step 5 - Generate the script

    ./bin/kubegen -f my-cluster.yaml
    # wrote create-dev-podman.sh - run it with: bash create-dev-podman.sh

If a tool is missing, kubegen writes nothing and tells you what to install:

    error: 1 tool(s) required for provider "kind" (shell) are not installed or not in PATH:
      - podman (runs the kind nodes)
          install it from: https://podman.io/docs/installation
    Nothing was written. Install the tools, or pass -skip-tool-check to generate anyway.

To look at the script without writing a file:

    ./bin/kubegen -f my-cluster.yaml -o -

A ready-made example of the result is in `podman/output/create-dev-podman.sh`.

## Step 6 - Create the cluster

    ./create-dev-podman.sh

The script, in order:

1. Checks that podman, kind and kubectl are installed.
2. Sets `KIND_EXPERIMENTAL_PROVIDER=podman` (this is what tells kind to use
   Podman) and checks that `podman info` works.
3. Runs `kind create cluster` with your node counts, ports and version.
4. Runs `kubectl get nodes` to show the result.

Creation usually takes one to three minutes; the first run is slower because
the node image is downloaded.

## Step 7 - (Alternative) Terraform instead of a script

    ./bin/kubegen -f my-cluster.yaml -format terraform
    cd terraform-dev-podman

    export KIND_EXPERIMENTAL_PROVIDER=podman      # required: do this before terraform
    terraform init
    terraform apply

To change settings without editing the YAML, copy
`terraform.tfvars.example` to `terraform.tfvars` and uncomment what you want
to override, for example:

    worker_nodes = 3
    extra_port_mappings = [
      { container_port = 30080, host_port = 8080 },
    ]

Remove the cluster with `terraform destroy` (same environment variable set).
A ready-made example is in `podman/output/terraform/`.

## Step 8 - Use the cluster

    kubectl get nodes
    kubectl cluster-info --context kind-dev-podman

The nodes are ordinary Podman containers:

    podman ps

To use an image you built locally with Podman, save it and load the archive
into the cluster:

    podman save localhost/myapp:latest -o myapp.tar
    KIND_EXPERIMENTAL_PROVIDER=podman kind load image-archive myapp.tar --name dev-podman

## Step 9 - Delete the cluster

    KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name dev-podman

Every kind command you run by hand needs that variable. To avoid repeating
it, add this to your shell profile:

    export KIND_EXPERIMENTAL_PROVIDER=podman

---

## Troubleshooting

| Problem                                                        | What to do                                                                 |
|----------------------------------------------------------------|----------------------------------------------------------------------------|
| `required tool 'podman' is not installed or not in PATH`       | Install Podman: <https://podman.io/docs/installation>                      |
| `Podman is installed but not usable`                           | macOS/Windows: `podman machine start`. Linux: run `podman info` and fix the error it shows. |
| Error about binding port 80 or 443, or "permission denied" on a port | Rootless Podman cannot use ports below 1024. Remove `ingressReady`, use high `hostPort` values. |
| Cluster creation fails right after "Starting control-plane"    | Usually missing cgroup delegation on Linux - redo Step 2.                  |
| Nodes are slow or the cluster never becomes ready (macOS/Windows) | Give the machine more resources: `podman machine stop`, `podman machine set --cpus 4 --memory 8192`, `podman machine start`. |
| `kind get clusters` shows nothing although the cluster exists  | The command ran without `KIND_EXPERIMENTAL_PROVIDER=podman`, so kind looked in Docker. |
| `kubernetesVersion: kind needs a full patch version`           | Use e.g. `"1.33.1"`, or set `kind.nodeImage`.                              |
| `podman/kubegen.sh` cannot find your YAML                      | Run it from the project root with a relative path inside that directory.   |

## Quick reference

    # generate
    ./bin/kubegen -f my-cluster.yaml                      # shell script
    ./bin/kubegen -f my-cluster.yaml -format terraform    # Terraform directory
    podman/kubegen.sh -f my-cluster.yaml                  # same, without Go

    # create / inspect / delete
    ./create-dev-podman.sh
    kubectl get nodes
    KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name dev-podman
