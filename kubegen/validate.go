package main

import (
	"fmt"
	"regexp"
	"strings"
)

var (
	nameRe     = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`)
	aksPoolRe  = regexp.MustCompile(`^[a-z][a-z0-9]{0,11}$`)
	durationRe = regexp.MustCompile(`^[0-9]+[smh]$`)
	patchVerRe = regexp.MustCompile(`^v?[0-9]+\.[0-9]+\.[0-9]+$`)
)

// validate checks the config against the rules in schema/cluster.schema.yaml
// and returns every problem found, plus non-fatal warnings.
func validate(c *Config) (errs, warns []string) {
	bad := func(format string, a ...any) { errs = append(errs, fmt.Sprintf(format, a...)) }
	warn := func(format string, a ...any) { warns = append(warns, fmt.Sprintf(format, a...)) }

	if c.APIVersion != "kubegen/v1" {
		bad("apiVersion: must be \"kubegen/v1\" (got %q)", c.APIVersion)
	}
	if !nameRe.MatchString(c.Name) || len(c.Name) > 63 {
		bad("name: %q must be a lowercase DNS label (a-z, 0-9, '-'; max 63 chars)", c.Name)
	}
	for k := range c.Tags {
		if k == "" {
			bad("tags: empty key")
		}
	}

	needRegion := func() {
		if c.Region == "" {
			bad("region: required for provider %q", c.Provider)
		}
	}
	// Pool checks shared by the cloud providers. unsupported lists pool
	// fields the provider cannot express.
	checkPools := func(sizeRequired bool, unsupported ...string) {
		if len(c.NodePools) == 0 {
			bad("nodePools: at least one pool is required for provider %q", c.Provider)
		}
		seen := map[string]bool{}
		for i, p := range c.NodePools {
			at := fmt.Sprintf("nodePools[%d] (%s)", i, p.Name)
			if !nameRe.MatchString(p.Name) || len(p.Name) > 63 {
				bad("%s: name must be a lowercase DNS label", at)
			}
			if seen[p.Name] {
				bad("%s: duplicate pool name", at)
			}
			seen[p.Name] = true
			if sizeRequired && p.Size == "" {
				bad("%s: size is required", at)
			}
			if p.Count != nil && *p.Count < 0 {
				bad("%s: count must be >= 0", at)
			}
			if p.DiskSizeGB < 0 {
				bad("%s: diskSizeGB must be positive", at)
			}
			if p.autoscaled() {
				a := p.Autoscaling
				if a.Max < 1 || a.Min < 0 || a.Min > a.Max {
					bad("%s: autoscaling needs 0 <= min <= max and max >= 1", at)
				} else if n := p.initialCount(); n < a.Min || n > a.Max {
					bad("%s: count %d is outside autoscaling range %d-%d", at, n, a.Min, a.Max)
				}
			}
			for j, t := range p.Taints {
				if t.Key == "" {
					bad("%s: taints[%d].key is required", at, j)
				}
				switch t.Effect {
				case "NoSchedule", "PreferNoSchedule", "NoExecute":
				default:
					bad("%s: taints[%d].effect must be NoSchedule, PreferNoSchedule or NoExecute", at, j)
				}
			}
			set := map[string]bool{
				"diskSizeGB": p.DiskSizeGB != 0, "zones": len(p.Zones) > 0,
				"labels": len(p.Labels) > 0, "taints": len(p.Taints) > 0, "spot": p.Spot,
			}
			for _, f := range unsupported {
				if set[f] {
					bad("%s: %s is not supported for provider %q", at, f, c.Provider)
				}
			}
		}
	}
	duration := func(field, v string) {
		if v != "" && !durationRe.MatchString(v) {
			bad("%s: %q must be a number followed by s, m or h (e.g. 120s)", field, v)
		}
	}

	switch c.Provider {
	case "kind":
		k := c.Kind
		if k == nil {
			k = &KindConfig{}
			c.Kind = k
		}
		if k.NodeImage == "" && c.KubernetesVersion != "" && !patchVerRe.MatchString(c.KubernetesVersion) {
			bad("kubernetesVersion: kind needs a full patch version such as \"1.33.1\" (or set kind.nodeImage)")
		}
		if k.ControlPlaneNodes < 0 || k.WorkerNodes < 0 {
			bad("kind: controlPlaneNodes and workerNodes must not be negative")
		}
		for i, m := range k.ExtraPortMappings {
			if m.ContainerPort < 1 || m.ContainerPort > 65535 || m.HostPort < 1 || m.HostPort > 65535 {
				bad("kind.extraPortMappings[%d]: containerPort and hostPort must be 1-65535", i)
			}
			switch m.Protocol {
			case "", "TCP", "UDP", "SCTP":
			default:
				bad("kind.extraPortMappings[%d]: protocol must be TCP, UDP or SCTP", i)
			}
		}
		duration("kind.waitTimeout", k.WaitTimeout)
		if len(c.NodePools) > 0 {
			warn("nodePools is ignored for kind; use kind.controlPlaneNodes / kind.workerNodes")
		}
		if len(c.Tags) > 0 {
			warn("tags is ignored for kind")
		}

	case "aks":
		needRegion()
		checkPools(true)
		if c.AKS == nil || c.AKS.ResourceGroup == "" {
			bad("aks.resourceGroup: required")
			break
		}
		a := c.AKS
		oneOf := func(field, v string, allowed ...string) {
			if v == "" {
				return
			}
			for _, x := range allowed {
				if v == x {
					return
				}
			}
			bad("%s: %q must be one of %s", field, v, strings.Join(allowed, ", "))
		}
		oneOf("aks.tier", a.Tier, "free", "standard", "premium")
		oneOf("aks.networkPlugin", a.NetworkPlugin, "azure", "kubenet", "none")
		oneOf("aks.networkPluginMode", a.NetworkPluginMode, "overlay")
		oneOf("aks.networkPolicy", a.NetworkPolicy, "azure", "calico", "cilium", "none")
		for i, p := range c.NodePools {
			if !aksPoolRe.MatchString(p.Name) {
				bad("nodePools[%d] (%s): AKS pool names are 1-12 lowercase letters/digits starting with a letter", i, p.Name)
			}
			if i == 0 && p.Spot {
				bad("nodePools[0] (%s): the first pool is the AKS system pool and cannot be spot", p.Name)
			}
			if i == 0 && p.initialCount() < 1 {
				bad("nodePools[0] (%s): the AKS system pool needs at least one node", p.Name)
			}
		}

	case "eks":
		needRegion()
		checkPools(true)
		if c.EKS == nil {
			c.EKS = &EKSConfig{}
		}
		switch c.EKS.NATGateway {
		case "", "Single", "HighlyAvailable", "Disable":
		default:
			bad("eks.natGateway: must be Single, HighlyAvailable or Disable")
		}
		if n := len(c.EKS.AvailabilityZones); n == 1 {
			bad("eks.availabilityZones: EKS needs at least two zones")
		}

	case "vks":
		checkPools(false, "diskSizeGB", "zones", "labels", "taints", "spot")
		if c.KubernetesVersion == "" {
			bad("kubernetesVersion: required for vks (see `kubectl get kr`)")
		}
		v := c.VKS
		if v == nil {
			bad("vks: block is required for provider \"vks\"")
			break
		}
		for field, val := range map[string]string{
			"namespace": v.Namespace, "clusterClass": v.ClusterClass,
			"vmClass": v.VMClass, "storageClass": v.StorageClass,
		} {
			if val == "" {
				bad("vks.%s: required", field)
			}
		}
		switch v.ControlPlaneReplicas {
		case 0, 1, 3, 5:
		default:
			bad("vks.controlPlaneReplicas: must be 1, 3 or 5")
		}
		if l := v.Login; l != nil {
			switch l.Method {
			case "kubectl-vsphere":
				if l.Server == "" || l.Username == "" {
					bad("vks.login: server and username are required for method kubectl-vsphere")
				}
			case "none":
			default:
				bad("vks.login.method: must be kubectl-vsphere or none")
			}
		}
		duration("vks.waitTimeout", v.WaitTimeout)

	case "dks":
		needRegion()
		checkPools(true, "diskSizeGB", "zones", "spot")
		if c.DKS == nil {
			c.DKS = &DKSConfig{}
		}

	default:
		bad("provider: %q must be one of kind, aks, eks, vks, dks", c.Provider)
	}
	return errs, warns
}
