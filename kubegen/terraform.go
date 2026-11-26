package main

import (
	"embed"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Static, commented Terraform for each provider. The cluster-specific part
// is variables.tf, whose defaults are generated from the cluster definition.
//
//go:embed templates
var templates embed.FS

// ---------------------------------------------------------------------------
// HCL value rendering
// ---------------------------------------------------------------------------

// hclObj is an HCL object with a fixed key order.
type hclObj []hclKV

type hclKV struct {
	K string
	V any
}

var hclIdentRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]*$`)

func hclString(s string) string {
	s = strconv.Quote(s)
	// keep literal ${ and %{ from being read as template sequences
	s = strings.ReplaceAll(s, "${", "$${")
	return strings.ReplaceAll(s, "%{", "%%{")
}

func hclKey(k string) string {
	if hclIdentRe.MatchString(k) {
		return k
	}
	return hclString(k)
}

// hcl renders a Go value as an HCL expression. Supported: nil, string, int,
// bool, []string, []any, map[string]string and hclObj.
func hcl(v any) string {
	switch v := v.(type) {
	case nil:
		return "null"
	case string:
		return hclString(v)
	case int:
		return strconv.Itoa(v)
	case bool:
		return strconv.FormatBool(v)
	case []string:
		items := make([]string, len(v))
		for i, s := range v {
			items[i] = hclString(s)
		}
		return "[" + strings.Join(items, ", ") + "]"
	case []any:
		if len(v) == 0 {
			return "[]"
		}
		var b strings.Builder
		b.WriteString("[\n")
		for _, item := range v {
			b.WriteString("  " + indentTail(hcl(item)) + ",\n")
		}
		b.WriteString("]")
		return b.String()
	case map[string]string:
		obj := hclObj{}
		for _, k := range sortedKeys(v) {
			obj = append(obj, hclKV{k, v[k]})
		}
		return hcl(obj)
	case hclObj:
		if len(v) == 0 {
			return "{}"
		}
		width := 0
		for _, kv := range v {
			width = max(width, len(hclKey(kv.K)))
		}
		var b strings.Builder
		b.WriteString("{\n")
		for _, kv := range v {
			fmt.Fprintf(&b, "  %-*s = %s\n", width, hclKey(kv.K), indentTail(hcl(kv.V)))
		}
		b.WriteString("}")
		return b.String()
	}
	panic(fmt.Sprintf("hcl: unsupported type %T", v))
}

// indentTail indents every line but the first by two spaces.
func indentTail(s string) string {
	return strings.ReplaceAll(s, "\n", "\n  ")
}

// orNull maps the zero value to HCL null.
func orNull[T comparable](v T) any {
	var zero T
	if v == zero {
		return nil
	}
	return v
}

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

// tfVar is one input variable: declared in variables.tf with Value as its
// default and listed (commented out) in terraform.tfvars.example.
type tfVar struct {
	Name  string
	Type  string // HCL type expression
	Desc  string
	Value any
	Hint  string // extra guidance shown in terraform.tfvars.example
}

const (
	tfAutoscaling = "optional(object({ min = number, max = number }))"

	tfTaintObjects = "optional(list(object({ key = string, value = optional(string), effect = string })), [])"

	hintAutoscale = "Fixed size: set node_count. Autoscaled: set autoscaling = { min = 1, max = 5 } instead."
)

func str(name, desc string, v any) tfVar {
	return tfVar{Name: name, Type: "string", Desc: desc, Value: v}
}
func num(name, desc string, v any) tfVar {
	return tfVar{Name: name, Type: "number", Desc: desc, Value: v}
}
func flag_(name, desc string, v bool) tfVar {
	return tfVar{Name: name, Type: "bool", Desc: desc, Value: v}
}

// autoscalingValue renders a pool's autoscaling bounds, or nil.
func autoscalingValue(p NodePool) any {
	if !p.autoscaled() {
		return nil
	}
	return hclObj{{"min", p.Autoscaling.Min}, {"max", p.Autoscaling.Max}}
}

// sizing returns the node_count or autoscaling entry for a pool.
func sizing(p NodePool) hclKV {
	if p.autoscaled() {
		return hclKV{"autoscaling", autoscalingValue(p)}
	}
	return hclKV{"node_count", p.initialCount()}
}

func taintObjects(ts []Taint) []any {
	var out []any
	for _, t := range ts {
		o := hclObj{{"key", t.Key}}
		if t.Value != "" {
			o = append(o, hclKV{"value", t.Value})
		}
		out = append(out, append(o, hclKV{"effect", t.Effect}))
	}
	return out
}

func kindVars(c *Config) []tfVar {
	k := c.Kind
	image := k.NodeImage
	if image == "" && c.KubernetesVersion != "" {
		image = "kindest/node:v" + strings.TrimPrefix(c.KubernetesVersion, "v")
	}
	var ports []any
	for _, p := range k.ExtraPortMappings {
		o := hclObj{{"container_port", p.ContainerPort}, {"host_port", p.HostPort}}
		if p.Protocol != "" {
			o = append(o, hclKV{"protocol", p.Protocol})
		}
		ports = append(ports, o)
	}
	vars := []tfVar{
		str("name", "Cluster name.", c.Name),
		{Name: "node_image", Type: "string", Value: orNull(image),
			Desc: "Node image, which sets the Kubernetes version. null = the provider's default.",
			Hint: "Image tags are listed in the kind release notes, e.g. \"kindest/node:v1.33.1\"."},
		num("control_plane_nodes", "Number of control-plane nodes (1, or 3 for an HA test setup).", max(k.ControlPlaneNodes, 1)),
		num("worker_nodes", "Number of worker nodes. 0 = workloads run on the control plane.", k.WorkerNodes),
		flag_("ingress_ready", "Label the first control-plane node ingress-ready=true and publish host ports 80 and 443.", k.IngressReady),
		{Name: "extra_port_mappings", Value: ports,
			Type: "list(object({\n  container_port = number\n  host_port      = number\n  protocol       = optional(string, \"TCP\")\n}))",
			Desc: "Extra host ports published on the first control-plane node.",
			Hint: "Example: [{ container_port = 30080, host_port = 8080 }] exposes NodePort 30080 on localhost:8080."},
		str("api_server_address", "Host address the API server listens on. null = 127.0.0.1.", orNull(k.APIServerAddress)),
		num("api_server_port", "Host port of the API server. null = a random free port.", orNull(k.APIServerPort)),
		str("pod_subnet", "Pod network CIDR. null = kind default.", orNull(k.PodSubnet)),
		str("service_subnet", "Service network CIDR. null = kind default.", orNull(k.ServiceSubnet)),
		flag_("disable_default_cni", "Skip kindnet so another CNI (Cilium, Calico, ...) can be installed.", k.DisableDefaultCNI),
		str("kubeconfig_path", "File to write the kubeconfig to. null = merge into ~/.kube/config.", orNull(c.Kubeconfig.Path)),
	}
	if k.Runtime == "podman" {
		wait := k.WaitTimeout
		if wait == "" {
			wait = "120s"
		}
		vars = append(vars, str("wait_timeout", "How long kind waits for the control plane to be ready, e.g. 120s or 5m.", wait))
	}
	return vars
}

func aksVars(c *Config) []tfVar {
	a := c.AKS
	plugin, mode := a.NetworkPlugin, a.NetworkPluginMode
	if plugin == "" { // same default as `az aks create`
		plugin = "azure"
		if mode == "" {
			mode = "overlay"
		}
	}
	policy := a.NetworkPolicy
	if policy == "none" {
		policy = ""
	}
	tier := "Free"
	if a.Tier != "" {
		tier = strings.ToUpper(a.Tier[:1]) + a.Tier[1:]
	}
	admin := a.AdminUsername
	if admin == "" {
		admin = "azureuser"
	}

	// Fields shared by the system pool and user pools.
	poolBase := func(p NodePool) hclObj {
		o := hclObj{{"vm_size", p.Size}, sizing(p)}
		if p.DiskSizeGB != 0 {
			o = append(o, hclKV{"os_disk_size_gb", p.DiskSizeGB})
		}
		if len(p.Zones) > 0 {
			o = append(o, hclKV{"zones", p.Zones})
		}
		if len(p.Labels) > 0 {
			o = append(o, hclKV{"labels", p.Labels})
		}
		return o
	}
	sys := c.NodePools[0]
	system := append(hclObj{{"name", sys.Name}}, poolBase(sys)...)
	users := hclObj{}
	for _, p := range c.NodePools[1:] {
		o := poolBase(p)
		if len(p.Taints) > 0 {
			o = append(o, hclKV{"taints", taintStrings(p.Taints)})
		}
		if p.Spot {
			o = append(o, hclKV{"spot", true})
		}
		users = append(users, hclKV{p.Name, o})
	}

	const poolFields = "  vm_size         = string\n  node_count      = optional(number, 1)\n  autoscaling     = " + tfAutoscaling +
		"\n  os_disk_size_gb = optional(number)\n  zones           = optional(list(string))\n  labels          = optional(map(string), {})\n"
	return []tfVar{
		str("name", "Cluster name.", c.Name),
		str("location", "Azure region.", c.Region),
		str("subscription_id", "Azure subscription ID. null = taken from ARM_SUBSCRIPTION_ID.", orNull(a.Subscription)),
		str("resource_group_name", "Resource group for the cluster.", a.ResourceGroup),
		flag_("create_resource_group", "Create the resource group (true) or use an existing one (false).", a.CreateResourceGroup),
		str("kubernetes_version", "Kubernetes version, e.g. \"1.33\". null = AKS default.", orNull(c.KubernetesVersion)),
		str("sku_tier", "Control plane tier: Free, Standard (uptime SLA) or Premium (long-term support).", tier),
		{Name: "tags", Type: "map(string)", Desc: "Tags applied to the resource group and cluster.", Value: c.Tags},
		{Name: "system_node_pool", Value: system,
			Type: "object({\n  name            = string\n" + poolFields + "})",
			Desc: "System node pool (runs cluster components). Needs at least one node.",
			Hint: hintAutoscale + " Changing vm_size or zones recreates the pool."},
		{Name: "user_node_pools", Value: users,
			Type: "map(object({\n" + poolFields + "  taints          = optional(list(string), [])\n  spot            = optional(bool, false)\n}))",
			Desc: "User node pools, keyed by pool name (1-12 lowercase letters/digits).",
			Hint: hintAutoscale + "\nTo add a pool, add an entry:\n  gpu = {\n    vm_size    = \"Standard_NC6s_v3\"\n    node_count = 1\n    taints     = [\"sku=gpu:NoSchedule\"]\n  }"},
		str("network_plugin", "Network plugin: azure, kubenet or none (bring your own CNI).", plugin),
		str("network_plugin_mode", "\"overlay\" gives pods addresses from pod_cidr instead of the VNet. null = VNet addresses.", orNull(mode)),
		str("network_policy", "Network policy engine: azure, calico or cilium. null = none.", orNull(policy)),
		str("pod_cidr", "Pod CIDR (overlay or kubenet). null = AKS default.", orNull(a.PodCIDR)),
		str("service_cidr", "Service CIDR. null = AKS default.", orNull(a.ServiceCIDR)),
		str("dns_service_ip", "Cluster DNS service IP, inside service_cidr. null = AKS default.", orNull(a.DNSServiceIP)),
		str("vnet_subnet_id", "Resource ID of an existing subnet for the nodes. null = AKS-managed VNet.", orNull(a.VnetSubnetID)),
		flag_("private_cluster_enabled", "Expose the API server only inside the virtual network.", a.PrivateCluster),
		flag_("oidc_issuer_enabled", "Enable the OIDC issuer URL.", a.EnableOIDCIssuer),
		flag_("workload_identity_enabled", "Enable Microsoft Entra Workload ID (also enables the OIDC issuer).", a.EnableWorkloadIdentity),
		str("acr_id", "Resource ID of a container registry the nodes may pull from. null = none.", orNull(a.AttachACR)),
		str("admin_username", "Linux admin user on the nodes (used with ssh_public_key_path).", admin),
		str("ssh_public_key_path", "SSH public key file for node access. null = no SSH access configured.", orNull(a.SSHPublicKeyPath)),
		str("kubeconfig_path", "File to write the admin kubeconfig to. null = do not write a file.", orNull(c.Kubeconfig.Path)),
	}
}

// eksAMITypes maps eksctl AMI family names to EKS node group AMI types.
var eksAMITypes = map[string]string{
	"AmazonLinux2023": "AL2023_x86_64_STANDARD",
	"AmazonLinux2":    "AL2_x86_64",
	"Bottlerocket":    "BOTTLEROCKET_x86_64",
}

func eksAMIType(family string) (string, bool) {
	if family == "" {
		return "", true
	}
	if t, ok := eksAMITypes[family]; ok {
		return t, true
	}
	// already an EKS AMI type such as AL2023_ARM_64_STANDARD
	if regexp.MustCompile(`^[A-Z0-9]+(_[A-Za-z0-9]+)+$`).MatchString(family) {
		return family, true
	}
	return "", false
}

func eksVars(c *Config) []tfVar {
	e := c.EKS
	pools := hclObj{}
	for _, p := range c.NodePools {
		minSize, maxSize := p.initialCount(), p.initialCount()
		if p.autoscaled() {
			minSize, maxSize = p.Autoscaling.Min, p.Autoscaling.Max
		}
		o := hclObj{{"instance_type", p.Size}, {"desired_size", p.initialCount()}, {"min_size", minSize}, {"max_size", maxSize}}
		if p.DiskSizeGB != 0 {
			o = append(o, hclKV{"disk_size_gb", p.DiskSizeGB})
		}
		if len(p.Zones) > 0 {
			o = append(o, hclKV{"zones", p.Zones})
		}
		if len(p.Labels) > 0 {
			o = append(o, hclKV{"labels", p.Labels})
		}
		if len(p.Taints) > 0 {
			o = append(o, hclKV{"taints", taintObjects(p.Taints)})
		}
		if p.Spot {
			o = append(o, hclKV{"spot", true})
		}
		pools = append(pools, hclKV{p.Name, o})
	}
	vpcCIDR := e.VPCCIDR
	if vpcCIDR == "" {
		vpcCIDR = "192.168.0.0/16" // eksctl's default
	}
	nat := e.NATGateway
	if nat == "" {
		nat = "Single"
	}
	amiType, _ := eksAMIType(e.AMIFamily)
	zones := e.AvailabilityZones
	if zones == nil {
		zones = []string{}
	}
	addons := e.Addons
	if addons == nil {
		addons = []string{}
	}
	return []tfVar{
		str("name", "Cluster name; also prefixes the VPC and IAM role names.", c.Name),
		str("region", "AWS region.", c.Region),
		str("aws_profile", "AWS CLI profile to use. null = default credential chain.", orNull(e.Profile)),
		str("kubernetes_version", "Kubernetes version, e.g. \"1.33\". null = current EKS default.", orNull(c.KubernetesVersion)),
		{Name: "tags", Type: "map(string)", Desc: "Tags applied to every AWS resource.", Value: c.Tags},
		{Name: "availability_zones", Type: "list(string)", Value: zones,
			Desc: "Zones to create subnets in (at least two). [] = the region's first three."},
		str("vpc_cidr", "CIDR of the new VPC; split into 16 equal subnet blocks.", vpcCIDR),
		{Name: "nat_gateway", Type: "string", Value: nat,
			Desc: "NAT for the private subnets: Single, HighlyAvailable (one per zone) or Disable.",
			Hint: "Single is cheapest. Use HighlyAvailable for production."},
		flag_("endpoint_public_access", "Make the API server reachable from the internet.", e.EndpointPublicAccess == nil || *e.EndpointPublicAccess),
		flag_("endpoint_private_access", "Make the API server reachable from inside the VPC.", e.EndpointPrivateAccess != nil && *e.EndpointPrivateAccess),
		flag_("private_networking", "Place nodes in the private subnets (no public IPs; needs a NAT gateway).", e.PrivateNetworking),
		flag_("enable_oidc", "Create the IAM OIDC provider, needed for IAM Roles for Service Accounts.", e.WithOIDC),
		{Name: "addons", Type: "list(string)", Value: addons,
			Desc: "EKS managed add-ons to install, e.g. vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver."},
		str("ami_type", "Node AMI type, e.g. AL2023_x86_64_STANDARD or BOTTLEROCKET_x86_64. null = EKS default.", orNull(amiType)),
		{Name: "node_pools", Value: pools,
			Type: "map(object({\n  instance_type = string\n  desired_size  = number\n  min_size      = number\n  max_size      = number\n" +
				"  disk_size_gb  = optional(number)\n  zones         = optional(list(string), [])\n  labels        = optional(map(string), {})\n" +
				"  taints        = " + tfTaintObjects + "\n  spot          = optional(bool, false)\n}))",
			Desc: "Managed node groups, keyed by group name.",
			Hint: "Keep min_size <= desired_size <= max_size.\nTo add a group, add an entry:\n  memory = {\n    instance_type = \"r6i.xlarge\"\n    desired_size  = 2\n    min_size      = 2\n    max_size      = 4\n    labels        = { workload = \"memory\" }\n  }"},
		str("kubeconfig_path", "Kubeconfig file used in the update_kubeconfig_command output. null = default.", orNull(c.Kubeconfig.Path)),
	}
}

func vksVars(c *Config) []tfVar {
	v := c.VKS
	apiVersion := v.APIVersion
	if apiVersion == "" {
		apiVersion = "cluster.x-k8s.io/v1beta1"
	}
	condition := "Available"
	if strings.HasSuffix(apiVersion, "/v1beta1") {
		condition = "Ready"
	}
	// kubectl vsphere login names the context after the vSphere Namespace.
	var context any
	if l := v.Login; l != nil {
		switch {
		case l.Context != "":
			context = l.Context
		case l.Method == "kubectl-vsphere":
			context = v.Namespace
		}
	}
	pools := hclObj{}
	for _, p := range c.NodePools {
		o := hclObj{sizing(p)}
		if p.Size != "" && p.Size != v.VMClass {
			o = append(o, hclKV{"vm_class", p.Size})
		}
		pools = append(pools, hclKV{p.Name, o})
	}
	replicas := v.ControlPlaneReplicas
	if replicas == 0 {
		replicas = 1
	}
	wait := v.WaitTimeout
	if wait == "" {
		wait = "30m"
	}
	kubeconfig := c.Kubeconfig.Path
	if kubeconfig == "" {
		kubeconfig = "./" + c.Name + ".kubeconfig"
	}
	return []tfVar{
		str("name", "Cluster name.", c.Name),
		str("namespace", "vSphere Namespace the cluster is created in.", v.Namespace),
		str("supervisor_kubeconfig_path", "Kubeconfig holding your Supervisor login.", "~/.kube/config"),
		str("supervisor_context", "Context for the vSphere Namespace in that kubeconfig. null = current context.", context),
		{Name: "kubernetes_version", Type: "string", Value: c.KubernetesVersion,
			Desc: "Kubernetes release to run.", Hint: "List the releases your Supervisor offers: kubectl get kr"},
		{Name: "cluster_class", Type: "string", Value: v.ClusterClass,
			Desc: "ClusterClass the cluster is built from.", Hint: "List them: kubectl get clusterclass -A"},
		str("cluster_class_namespace", "Namespace of the ClusterClass when it is not in `namespace`. null = same namespace.", orNull(v.ClusterClassNamespace)),
		str("cluster_api_version", "Cluster API version served by the Supervisor.", apiVersion),
		str("ready_condition", "Cluster condition to wait for: Ready on v1beta1, Available on v1beta2.", condition),
		num("control_plane_replicas", "Control-plane nodes: 1, 3 or 5.", replicas),
		{Name: "vm_class", Type: "string", Value: v.VMClass,
			Desc: "VM class for the control plane and for pools without their own.", Hint: "List them: kubectl get vmclass"},
		str("storage_class", "Storage class (storage policy) for node disks.", v.StorageClass),
		str("pod_cidr", "Pod network CIDR. null = ClusterClass default.", orNull(v.PodCIDR)),
		str("service_cidr", "Service network CIDR. null = ClusterClass default.", orNull(v.ServiceCIDR)),
		str("service_domain", "Cluster DNS domain. null = cluster.local.", orNull(v.ServiceDomain)),
		{Name: "labels", Type: "map(string)", Desc: "Labels set on the Cluster object.", Value: c.Tags},
		{Name: "node_pools", Value: pools,
			Type: "map(object({\n  node_count  = optional(number, 1)\n  vm_class    = optional(string)\n  autoscaling = " + tfAutoscaling + "\n}))",
			Desc: "Worker node pools, keyed by pool name.",
			Hint: hintAutoscale + "\nTo add a pool, add an entry:\n  gpu = {\n    node_count = 2\n    vm_class   = \"guaranteed-xlarge\"\n  }"},
		str("wait_timeout", "How long to wait for the cluster to become ready, e.g. 30m.", wait),
		str("kubeconfig_path", "File the workload cluster kubeconfig is written to.", kubeconfig),
	}
}

func dksVars(c *Config) []tfVar {
	d := c.DKS
	version := c.KubernetesVersion
	if version == "" {
		version = "latest"
	}
	pool := func(p NodePool, withName bool) hclObj {
		o := hclObj{}
		if withName {
			o = append(o, hclKV{"name", p.Name})
		}
		o = append(o, hclKV{"size", p.Size}, sizing(p))
		if len(p.Labels) > 0 {
			o = append(o, hclKV{"labels", p.Labels})
		}
		if len(p.Taints) > 0 {
			o = append(o, hclKV{"taints", taintObjects(p.Taints)})
		}
		return o
	}
	extra := hclObj{}
	for _, p := range c.NodePools[1:] {
		extra = append(extra, hclKV{p.Name, pool(p, false)})
	}
	tags := []string{}
	for _, k := range sortedKeys(c.Tags) {
		tags = append(tags, k+":"+c.Tags[k])
	}
	var window any
	if day, start, ok := strings.Cut(d.MaintenanceWindow, "="); ok {
		window = hclObj{{"day", day}, {"start_time", start}}
	}

	const poolFields = "  size        = string\n  node_count  = optional(number, 1)\n  autoscaling = " + tfAutoscaling +
		"\n  labels      = optional(map(string), {})\n  taints      = " + tfTaintObjects + "\n"
	return []tfVar{
		str("name", "Cluster name.", c.Name),
		{Name: "region", Type: "string", Value: c.Region,
			Desc: "DigitalOcean region slug.", Hint: "List them: doctl kubernetes options regions"},
		{Name: "kubernetes_version", Type: "string", Value: version,
			Desc: "\"latest\", a prefix such as \"1.33.\" (newest matching patch), or a full slug such as \"1.33.1-do.0\".",
			Hint: "List the available slugs: doctl kubernetes options versions"},
		{Name: "tags", Type: "list(string)", Desc: "Tags applied to the cluster and its droplets.", Value: tags},
		flag_("ha", "Highly available control plane. Cannot be switched off once enabled.", d.HA),
		flag_("auto_upgrade", "Install patch releases automatically during the maintenance window.", d.AutoUpgrade),
		flag_("surge_upgrade", "Add temporary nodes during upgrades to keep capacity.", d.SurgeUpgrade),
		str("vpc_uuid", "UUID of the VPC to place the cluster in. null = the region's default VPC.", orNull(d.VPCUUID)),
		{Name: "maintenance_window", Type: "object({ day = string, start_time = string })", Value: window,
			Desc: "When automatic maintenance may start. null = chosen by DigitalOcean.",
			Hint: "Example: { day = \"saturday\", start_time = \"02:00\" } (UTC; day may be \"any\")."},
		{Name: "default_node_pool", Value: pool(c.NodePools[0], true),
			Type: "object({\n  name        = string\n" + poolFields + "})",
			Desc: "Default node pool. Changing its name or size replaces the cluster.",
			Hint: hintAutoscale + " List droplet sizes: doctl kubernetes options sizes"},
		{Name: "additional_node_pools", Value: extra,
			Type: "map(object({\n" + poolFields + "}))",
			Desc: "Additional node pools, keyed by pool name.",
			Hint: hintAutoscale + "\nTo add a pool, add an entry:\n  cpu = {\n    size       = \"c-8\"\n    node_count = 2\n    labels     = { workload = \"cpu\" }\n  }"},
		str("kubeconfig_path", "File to write the kubeconfig to. null = do not write a file.", orNull(c.Kubeconfig.Path)),
	}
}

func gksVars(c *Config) []tfVar {
	g := c.GKS
	pools := hclObj{}
	for _, p := range c.NodePools {
		o := hclObj{{"machine_type", p.Size}, sizing(p)}
		if p.DiskSizeGB != 0 {
			o = append(o, hclKV{"disk_size_gb", p.DiskSizeGB})
		}
		if len(p.Zones) > 0 {
			o = append(o, hclKV{"zones", p.Zones})
		}
		if len(p.Labels) > 0 {
			o = append(o, hclKV{"labels", p.Labels})
		}
		if len(p.Taints) > 0 {
			o = append(o, hclKV{"taints", taintObjects(p.Taints)})
		}
		if p.Spot {
			o = append(o, hclKV{"spot", true})
		}
		pools = append(pools, hclKV{p.Name, o})
	}
	return []tfVar{
		str("name", "Cluster name.", c.Name),
		str("project", "Google Cloud project ID.", g.Project),
		{Name: "location", Type: "string", Value: c.Region,
			Desc: "A region (us-central1) for a regional cluster, or a zone (us-central1-a) for a zonal one.",
			Hint: "Regional clusters put nodes in several zones, so node_count is per zone."},
		str("kubernetes_version", "Minimum Kubernetes version, e.g. \"1.33\". null = the release channel's default.", orNull(c.KubernetesVersion)),
		str("release_channel", "Automatic upgrade channel: rapid, regular, stable or none. null = GKE default.", orNull(g.ReleaseChannel)),
		{Name: "labels", Type: "map(string)", Desc: "Labels applied to the cluster (lowercase letters, digits, '-' and '_').", Value: c.Tags},
		str("network", "VPC network name. null = the project's default network.", orNull(g.Network)),
		str("subnetwork", "Subnetwork name. null = chosen by GKE.", orNull(g.Subnetwork)),
		str("pod_cidr", "Pod IP range. null = chosen by GKE.", orNull(g.PodCIDR)),
		str("service_cidr", "Service IP range. null = chosen by GKE.", orNull(g.ServiceCIDR)),
		flag_("private_nodes", "Give nodes private IP addresses only (they then need Cloud NAT to reach the internet).", g.PrivateNodes),
		str("master_cidr", "A /28 range for the control plane of a private cluster. null = chosen by GKE.", orNull(g.MasterCIDR)),
		flag_("workload_identity", "Enable Workload Identity so pods can use Google service accounts.", g.WorkloadIdentity),
		flag_("dataplane_v2", "Use Dataplane V2 (Cilium-based networking with built-in network policy).", g.DataplaneV2),
		{Name: "deletion_protection", Type: "bool", Value: g.DeletionProtection,
			Desc: "Block terraform destroy from deleting the cluster.",
			Hint: "Set to true for clusters you must not lose; set back to false and apply before destroying."},
		{Name: "node_pools", Value: pools,
			Type: "map(object({\n  machine_type = string\n  node_count   = optional(number, 1)\n  autoscaling  = " + tfAutoscaling +
				"\n  disk_size_gb = optional(number)\n  zones        = optional(list(string))\n  labels       = optional(map(string), {})\n" +
				"  taints       = " + tfTaintObjects + "\n  spot         = optional(bool, false)\n}))",
			Desc: "Node pools, keyed by pool name. Counts are per zone in a regional cluster.",
			Hint: hintAutoscale + "\nTo add a pool, add an entry:\n  highmem = {\n    machine_type = \"e2-highmem-4\"\n    node_count   = 1\n    labels       = { workload = \"memory\" }\n  }"},
		str("kubeconfig_path", "Kubeconfig file used in the get_credentials_command output. null = default.", orNull(c.Kubeconfig.Path)),
	}
}

func tfVars(c *Config) []tfVar {
	switch c.Provider {
	case "kind":
		return kindVars(c)
	case "aks":
		return aksVars(c)
	case "eks":
		return eksVars(c)
	case "vks":
		return vksVars(c)
	case "dks":
		return dksVars(c)
	case "gks":
		return gksVars(c)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Terraform-specific validation
// ---------------------------------------------------------------------------

// validateTerraform reports settings the Terraform output cannot express.
func validateTerraform(c *Config) (errs, warns []string) {
	switch c.Provider {
	case "kind":
		if c.Kind.WaitTimeout != "" && c.Kind.Runtime != "podman" {
			warns = append(warns, "kind.waitTimeout is not used by the Terraform output (the provider waits with its own timeout)")
		}
	case "aks":
		if len(c.NodePools[0].Taints) > 0 {
			errs = append(errs, fmt.Sprintf("nodePools[0] (%s): the azurerm provider cannot set taints on the system pool; move them to a user pool", c.NodePools[0].Name))
		}
		if id := c.AKS.AttachACR; id != "" && !strings.HasPrefix(id, "/subscriptions/") {
			errs = append(errs, "aks.attachACR: Terraform needs the registry's full resource ID (/subscriptions/...), not its name")
		}
		if c.AKS.AdminUsername != "" && c.AKS.SSHPublicKeyPath == "" {
			warns = append(warns, "aks.adminUsername only takes effect in Terraform together with aks.sshPublicKeyPath")
		}
	case "eks":
		if _, ok := eksAMIType(c.EKS.AMIFamily); !ok {
			errs = append(errs, fmt.Sprintf("eks.amiFamily: %q has no known EKS AMI type; use AmazonLinux2023, AmazonLinux2, Bottlerocket or an AMI type such as AL2023_ARM_64_STANDARD", c.EKS.AMIFamily))
		}
		if c.EKS.NATGateway == "Disable" && c.EKS.PrivateNetworking {
			warns = append(warns, "eks: privateNetworking with natGateway Disable leaves the nodes without internet access")
		}
	case "vks":
		warns = append(warns, "vks: Terraform does not log in to the Supervisor; run `kubectl vsphere login` (or your usual login) before terraform apply")
	case "dks":
		if w := c.DKS.MaintenanceWindow; w != "" && !regexp.MustCompile(`^[a-z]+=[0-9]{2}:[0-9]{2}$`).MatchString(w) {
			errs = append(errs, fmt.Sprintf("dks.maintenanceWindow: %q must look like \"saturday=02:00\"", w))
		}
		if c.DKS.Context != "" {
			warns = append(warns, "dks.context is not used by the Terraform output; the provider reads DIGITALOCEAN_TOKEN")
		}
	}
	return errs, warns
}

// ---------------------------------------------------------------------------
// File rendering
// ---------------------------------------------------------------------------

func comment(text string) string {
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight("# "+l, " ")
	}
	return strings.Join(lines, "\n") + "\n"
}

func renderVariablesTF(vars []tfVar, header string) string {
	var b strings.Builder
	b.WriteString(header)
	b.WriteString("#\n# Input variables. The defaults come from the cluster definition; override\n" +
		"# them in terraform.tfvars (see terraform.tfvars.example) rather than here,\n" +
		"# because this file is overwritten when kubegen runs again.\n")
	for _, v := range vars {
		fmt.Fprintf(&b, "\nvariable %q {\n", v.Name)
		fmt.Fprintf(&b, "  description = %s\n", hclString(v.Desc))
		fmt.Fprintf(&b, "  type        = %s\n", indentTail(v.Type))
		fmt.Fprintf(&b, "  default     = %s\n", indentTail(hcl(v.Value)))
		b.WriteString("}\n")
	}
	return b.String()
}

func renderTFVarsExample(vars []tfVar, c *Config, source string) string {
	var b strings.Builder
	b.WriteString(comment(fmt.Sprintf(
		"Example variable overrides for the %s cluster %q.\n\n"+
			"Copy this file to terraform.tfvars (loaded automatically), or to a file per\n"+
			"environment and pass it with -var-file:\n\n"+
			"  cp terraform.tfvars.example terraform.tfvars\n"+
			"  terraform apply\n\n"+
			"  terraform apply -var-file=staging.tfvars\n\n"+
			"Every setting below is commented out and shows its current default, which\n"+
			"was generated from %s. Uncomment a setting and change it to override the\n"+
			"default; settings you leave commented keep their default.",
		c.Provider, c.Name, source)))
	for _, v := range vars {
		b.WriteString("\n")
		b.WriteString(comment(v.Desc))
		if v.Hint != "" {
			b.WriteString(comment(v.Hint))
		}
		if v.Hint != "" && strings.Contains(v.Hint, "\n") {
			b.WriteString("#\n")
		}
		b.WriteString(comment(v.Name + " = " + hcl(v.Value)))
	}
	return b.String()
}

// templateDir is the embedded template set for c. kind on Podman has its
// own: the kind Terraform provider only talks to Docker, so that variant
// runs the kind CLI instead.
func templateDir(c *Config) string {
	if c.Provider == "kind" && c.Kind.Runtime == "podman" {
		return "kind-podman"
	}
	return c.Provider
}

// writeTerraform writes the Terraform configuration for c into dir and
// returns the files written.
func writeTerraform(c *Config, source, dir string) ([]string, error) {
	header := fmt.Sprintf("# Generated by kubegen from %s for the %s cluster %q.\n", source, c.Provider, c.Name)
	vars := tfVars(c)

	files := map[string]string{
		"variables.tf":             renderVariablesTF(vars, header),
		"terraform.tfvars.example": renderTFVarsExample(vars, c, source),
	}
	for _, name := range []string{"versions.tf", "main.tf", "outputs.tf"} {
		data, err := templates.ReadFile("templates/" + templateDir(c) + "/" + name)
		if err != nil {
			return nil, err
		}
		files[name] = header + "#\n" + string(data)
	}

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	var written []string
	for name, content := range files {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return nil, err
		}
		written = append(written, path)
	}
	sort.Strings(written)
	return written, nil
}
