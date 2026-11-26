package main

import "os/exec"

// Tool is a CLI the generated script depends on.
type Tool struct {
	Binary  string // executable looked up in PATH
	Purpose string
	URL     string // where to download / how to install
}

var (
	toolKubectl   = Tool{"kubectl", "talks to the cluster", "https://kubernetes.io/docs/tasks/tools/"}
	toolDocker    = Tool{"docker", "runs the kind nodes", "https://docs.docker.com/get-docker/"}
	toolPodman    = Tool{"podman", "runs the kind nodes", "https://podman.io/docs/installation"}
	toolKind      = Tool{"kind", "creates the local cluster", "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"}
	toolAz        = Tool{"az", "Azure CLI, creates the AKS cluster", "https://learn.microsoft.com/cli/azure/install-azure-cli"}
	toolAWS       = Tool{"aws", "AWS CLI, provides credentials for eksctl", "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"}
	toolEksctl    = Tool{"eksctl", "creates the EKS cluster", "https://eksctl.io/installation/"}
	toolTerraform = Tool{"terraform", "applies the generated Terraform configuration", "https://developer.hashicorp.com/terraform/install"}
	toolGcloud    = Tool{"gcloud", "Google Cloud CLI, creates the GKE cluster", "https://cloud.google.com/sdk/docs/install"}
	toolGKEAuth   = Tool{"gke-gcloud-auth-plugin", "lets kubectl log in to GKE; after installing gcloud run: gcloud components install gke-gcloud-auth-plugin", "https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl"}
	toolDoctl     = Tool{"doctl", "DigitalOcean CLI, creates the cluster", "https://docs.digitalocean.com/reference/doctl/how-to/install/"}
)

// requiredTools lists the CLIs needed to create the cluster described by c
// with the given output format ("shell" or "terraform").
func requiredTools(c *Config, format string) []Tool {
	if format == "terraform" {
		return terraformTools(c)
	}
	switch c.Provider {
	case "kind":
		return []Tool{kindRuntimeTool(c), toolKind, toolKubectl}
	case "aks":
		return []Tool{toolAz, toolKubectl}
	case "eks":
		return []Tool{toolAWS, toolEksctl, toolKubectl}
	case "dks":
		return []Tool{toolDoctl, toolKubectl}
	case "gks":
		return []Tool{toolGcloud, toolKubectl, toolGKEAuth}
	case "vks":
		tools := []Tool{toolKubectl}
		if l := c.VKS.Login; l != nil && l.Method == "kubectl-vsphere" {
			// The plugin is served by the Supervisor itself.
			tools = append(tools, Tool{
				"kubectl-vsphere", "vSphere plugin for kubectl, logs in to the Supervisor",
				"https://" + l.Server + "/ (Kubernetes CLI Tools page served by your Supervisor)",
			})
		}
		return tools
	}
	return nil
}

// kindRuntimeTool is the container engine kind runs its nodes in.
func kindRuntimeTool(c *Config) Tool {
	if c.Kind != nil && c.Kind.Runtime == "podman" {
		return toolPodman
	}
	return toolDocker
}

// missingTools returns the tools that are not on PATH.
func missingTools(tools []Tool) []Tool {
	var missing []Tool
	for _, t := range tools {
		if _, err := exec.LookPath(t.Binary); err != nil {
			missing = append(missing, t)
		}
	}
	return missing
}

// terraformTools lists what the Terraform configuration needs: terraform
// itself plus whatever the provider plugin relies on for access.
func terraformTools(c *Config) []Tool {
	tools := []Tool{toolTerraform}
	switch c.Provider {
	case "kind":
		tools = append(tools, kindRuntimeTool(c))
		if c.Kind.Runtime == "podman" {
			// the Podman variant runs the kind CLI rather than a provider plugin
			tools = append(tools, toolKind)
		}
	case "aks":
		az := toolAz
		az.Purpose = "Azure CLI, provides the login Terraform uses"
		tools = append(tools, az)
	case "eks":
		aws := toolAWS
		aws.Purpose = "AWS CLI, provides credentials and the kubeconfig command"
		tools = append(tools, aws)
	case "gks":
		gcloud := toolGcloud
		gcloud.Purpose = "Google Cloud CLI, provides the login Terraform uses"
		tools = append(tools, gcloud)
	case "vks":
		// kubectl runs the wait and kubeconfig steps; the vSphere plugin
		// is how you log in before terraform apply.
		tools = append(tools, requiredTools(c, "shell")...)
	}
	return tools
}
