# Using Podman

Two separate uses of Podman, both optional.

| File                         | Purpose                                                    |
|------------------------------|------------------------------------------------------------|
| `kind-podman.yaml`           | Example kind cluster whose nodes run in Podman             |
| `output/create-dev-podman.sh`| Shell script kubegen generates from it                     |
| `output/terraform/`          | Terraform kubegen generates from it                        |
| `Containerfile`              | Image that builds and holds kubegen                        |
| `kubegen.sh`                 | Runs kubegen in that image (no Go needed on the host)      |

## 1. kind clusters on Podman instead of Docker

Set the runtime in the cluster definition:

    provider: kind
    kind:
      runtime: podman

If you leave `runtime` out, kubegen picks for you: Docker when a Docker
daemon is running on the machine, otherwise Podman when it is installed. It
prints a note when it picks Podman. `podman/kubegen.sh` always defaults to
Podman. Setting the line explicitly is still the safest choice.

What changes:

- kubegen checks for `podman` instead of `docker` and, if it is missing,
  prints the install link: <https://podman.io/docs/installation>
- The generated script exports `KIND_EXPERIMENTAL_PROVIDER=podman`, which is
  how kind is told to use Podman, and checks `podman info` before starting.
- For Terraform output, kubegen writes a Podman-specific configuration that
  runs the `kind` command with Podman selected. The community kind provider
  for Terraform only talks to Docker, so it is not used here. `kind` must be
  installed; you do not set the variable yourself.

Step by step:

1. Install Podman, kind and kubectl.
2. macOS / Windows only: `podman machine init && podman machine start`
3. Generate and run:

       ./bin/kubegen -f podman/kind-podman.yaml
       ./create-dev-podman.sh

4. Remove the cluster when done:

       KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name dev-podman

Things to know about rootless Podman (the default on Linux):

- It cannot publish host ports below 1024, so `kind.ingressReady` (ports 80
  and 443) fails. Use `extraPortMappings` with high host ports, as the
  example does, or run Podman as root.
- kind needs cgroup v2 with CPU delegation for rootless use. If cluster
  creation fails early, see kind's rootless guide:
  <https://kind.sigs.k8s.io/docs/user/rootless/>

## 2. Running kubegen itself in Podman

Use this when you do not want to install Go. From the project root:

    podman/kubegen.sh -f podman/kind-podman.yaml
    podman/kubegen.sh -f examples/aks.yaml -format terraform

The first run builds the image from `Containerfile`; later runs reuse it
(`KUBEGEN_REBUILD=1 podman/kubegen.sh ...` rebuilds after code changes).

- The current directory is mounted into the container, so `-f` and `-o`
  must be relative paths inside it.
- The container holds only kubegen, so its tool check is skipped. The
  generated shell scripts still check for their tools when you run them.
