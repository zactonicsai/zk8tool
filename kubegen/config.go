package main

// Config mirrors schema/cluster.schema.yaml.
type Config struct {
	APIVersion        string            `yaml:"apiVersion"`
	Provider          string            `yaml:"provider"`
	Name              string            `yaml:"name"`
	KubernetesVersion string            `yaml:"kubernetesVersion"`
	Region            string            `yaml:"region"`
	Tags              map[string]string `yaml:"tags"`
	Kubeconfig        Kubeconfig        `yaml:"kubeconfig"`
	NodePools         []NodePool        `yaml:"nodePools"`

	Kind *KindConfig `yaml:"kind"`
	AKS  *AKSConfig  `yaml:"aks"`
	EKS  *EKSConfig  `yaml:"eks"`
	VKS  *VKSConfig  `yaml:"vks"`
	DKS  *DKSConfig  `yaml:"dks"`
	GKS  *GKSConfig  `yaml:"gks"`
}

type Kubeconfig struct {
	Path string `yaml:"path"`
}

type NodePool struct {
	Name        string            `yaml:"name"`
	Count       *int              `yaml:"count"`
	Size        string            `yaml:"size"`
	DiskSizeGB  int               `yaml:"diskSizeGB"`
	Autoscaling *Autoscaling      `yaml:"autoscaling"`
	Zones       []string          `yaml:"zones"`
	Labels      map[string]string `yaml:"labels"`
	Taints      []Taint           `yaml:"taints"`
	Spot        bool              `yaml:"spot"`
}

type Autoscaling struct {
	Enabled bool `yaml:"enabled"`
	Min     int  `yaml:"min"`
	Max     int  `yaml:"max"`
}

type Taint struct {
	Key    string `yaml:"key"`
	Value  string `yaml:"value"`
	Effect string `yaml:"effect"`
}

type KindConfig struct {
	Runtime           string        `yaml:"runtime"`
	NodeImage         string        `yaml:"nodeImage"`
	ControlPlaneNodes int           `yaml:"controlPlaneNodes"`
	WorkerNodes       int           `yaml:"workerNodes"`
	APIServerAddress  string        `yaml:"apiServerAddress"`
	APIServerPort     int           `yaml:"apiServerPort"`
	PodSubnet         string        `yaml:"podSubnet"`
	ServiceSubnet     string        `yaml:"serviceSubnet"`
	DisableDefaultCNI bool          `yaml:"disableDefaultCNI"`
	IngressReady      bool          `yaml:"ingressReady"`
	ExtraPortMappings []PortMapping `yaml:"extraPortMappings"`
	WaitTimeout       string        `yaml:"waitTimeout"`
}

type PortMapping struct {
	ContainerPort int    `yaml:"containerPort"`
	HostPort      int    `yaml:"hostPort"`
	Protocol      string `yaml:"protocol"`
}

type AKSConfig struct {
	Subscription           string `yaml:"subscription"`
	ResourceGroup          string `yaml:"resourceGroup"`
	CreateResourceGroup    bool   `yaml:"createResourceGroup"`
	Tier                   string `yaml:"tier"`
	NetworkPlugin          string `yaml:"networkPlugin"`
	NetworkPluginMode      string `yaml:"networkPluginMode"`
	NetworkPolicy          string `yaml:"networkPolicy"`
	PodCIDR                string `yaml:"podCidr"`
	ServiceCIDR            string `yaml:"serviceCidr"`
	DNSServiceIP           string `yaml:"dnsServiceIP"`
	VnetSubnetID           string `yaml:"vnetSubnetId"`
	PrivateCluster         bool   `yaml:"privateCluster"`
	EnableOIDCIssuer       bool   `yaml:"enableOIDCIssuer"`
	EnableWorkloadIdentity bool   `yaml:"enableWorkloadIdentity"`
	AttachACR              string `yaml:"attachACR"`
	AdminUsername          string `yaml:"adminUsername"`
	SSHPublicKeyPath       string `yaml:"sshPublicKeyPath"`
}

type EKSConfig struct {
	Profile               string   `yaml:"profile"`
	AvailabilityZones     []string `yaml:"availabilityZones"`
	VPCCIDR               string   `yaml:"vpcCidr"`
	NATGateway            string   `yaml:"natGateway"`
	EndpointPublicAccess  *bool    `yaml:"endpointPublicAccess"`
	EndpointPrivateAccess *bool    `yaml:"endpointPrivateAccess"`
	WithOIDC              bool     `yaml:"withOIDC"`
	Addons                []string `yaml:"addons"`
	PrivateNetworking     bool     `yaml:"privateNetworking"`
	AMIFamily             string   `yaml:"amiFamily"`
}

type VKSConfig struct {
	Login                 *VKSLogin `yaml:"login"`
	Namespace             string    `yaml:"namespace"`
	APIVersion            string    `yaml:"apiVersion"`
	ClusterClass          string    `yaml:"clusterClass"`
	ClusterClassNamespace string    `yaml:"clusterClassNamespace"`
	ControlPlaneReplicas  int       `yaml:"controlPlaneReplicas"`
	VMClass               string    `yaml:"vmClass"`
	StorageClass          string    `yaml:"storageClass"`
	PodCIDR               string    `yaml:"podCidr"`
	ServiceCIDR           string    `yaml:"serviceCidr"`
	ServiceDomain         string    `yaml:"serviceDomain"`
	WaitTimeout           string    `yaml:"waitTimeout"`
}

type VKSLogin struct {
	Method                string `yaml:"method"`
	Server                string `yaml:"server"`
	Username              string `yaml:"username"`
	InsecureSkipTLSVerify bool   `yaml:"insecureSkipTLSVerify"`
	Context               string `yaml:"context"`
}

type GKSConfig struct {
	Project            string `yaml:"project"`
	ReleaseChannel     string `yaml:"releaseChannel"`
	Network            string `yaml:"network"`
	Subnetwork         string `yaml:"subnetwork"`
	PodCIDR            string `yaml:"podCidr"`
	ServiceCIDR        string `yaml:"serviceCidr"`
	PrivateNodes       bool   `yaml:"privateNodes"`
	MasterCIDR         string `yaml:"masterCidr"`
	WorkloadIdentity   bool   `yaml:"workloadIdentity"`
	DataplaneV2        bool   `yaml:"dataplaneV2"`
	DeletionProtection bool   `yaml:"deletionProtection"`
}

type DKSConfig struct {
	Context           string `yaml:"context"`
	HA                bool   `yaml:"ha"`
	AutoUpgrade       bool   `yaml:"autoUpgrade"`
	SurgeUpgrade      bool   `yaml:"surgeUpgrade"`
	VPCUUID           string `yaml:"vpcUUID"`
	MaintenanceWindow string `yaml:"maintenanceWindow"`
}

// initialCount is the node count a pool starts with.
func (p NodePool) initialCount() int {
	if p.Count != nil {
		return *p.Count
	}
	if p.autoscaled() {
		return p.Autoscaling.Min
	}
	return 1
}

func (p NodePool) autoscaled() bool {
	return p.Autoscaling != nil && p.Autoscaling.Enabled
}
