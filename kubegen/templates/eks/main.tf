# Amazon EKS cluster with its own VPC and managed node groups.
#
# Authentication: the usual AWS credential chain (aws configure,
# aws sso login, or AWS_* environment variables). Set aws_profile to pick a
# named profile.
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply        # takes 15-20 minutes
#
# Override settings in terraform.tfvars (see terraform.tfvars.example).

provider "aws" {
  region  = var.region
  profile = var.aws_profile # null = default credential chain

  # Applied to every resource that supports tags.
  default_tags {
    tags = var.tags
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Zones to spread subnets over: the given list, or the region's first three.
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)

  # NAT gateways: none, one shared, or one per zone.
  nat_count = var.nat_gateway == "Disable" ? 0 : (var.nat_gateway == "Single" ? 1 : length(local.azs))
}

# ---------------------------------------------------------------------------
# Network: one public and one private subnet per zone.
# The VPC CIDR is split into /(prefix+4) blocks: 0-7 public, 8-15 private.
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required by EKS

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name}-public-${local.azs[count.index]}"
    # Lets Kubernetes place internet-facing load balancers here.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)

  tags = {
    Name = "${var.name}-private-${local.azs[count.index]}"
    # Lets Kubernetes place internal load balancers here.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(local.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT gateways give the private subnets outbound internet access (image
# pulls, AWS APIs). "Single" is cheapest; "HighlyAvailable" survives the
# loss of a zone; "Disable" leaves the private subnets without egress.
resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"
  tags   = { Name = "${var.name}-nat-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags       = { Name = "${var.name}-nat-${count.index}" }
  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  count = length(local.azs)

  vpc_id = aws_vpc.this.id

  # Route through this zone's NAT gateway, or the shared one.
  dynamic "route" {
    for_each = local.nat_count == 0 ? [] : [1]
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[local.nat_count == 1 ? 0 : count.index].id
    }
  }

  tags = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count = length(local.azs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# IAM roles for the control plane and the nodes
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name = "${var.name}-eks-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Minimum policies a worker node needs: join the cluster, pod networking,
# pull images from ECR.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.kubernetes_version # null = current EKS default
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
  }

  # Gives the identity running Terraform cluster-admin, like eksctl does.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# ---------------------------------------------------------------------------
# Managed node groups: one per entry in var.node_pools.
# Add, remove or resize groups by editing that map in terraform.tfvars.
# ---------------------------------------------------------------------------

locals {
  # private_networking = nodes get no public IP and reach the internet
  # through the NAT gateway.
  node_subnets = var.private_networking ? aws_subnet.private : aws_subnet.public

  # Kubernetes taint effect -> EKS API spelling.
  taint_effects = {
    NoSchedule       = "NO_SCHEDULE"
    PreferNoSchedule = "PREFER_NO_SCHEDULE"
    NoExecute        = "NO_EXECUTE"
  }
}

resource "aws_eks_node_group" "this" {
  for_each = var.node_pools

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn

  # All node subnets, or only those in the pool's zones.
  subnet_ids = [
    for s in local.node_subnets : s.id
    if length(each.value.zones) == 0 || contains(each.value.zones, s.availability_zone)
  ]

  instance_types = [each.value.instance_type]
  capacity_type  = each.value.spot ? "SPOT" : "ON_DEMAND"
  disk_size      = each.value.disk_size_gb
  ami_type       = var.ami_type # null = EKS default for the Kubernetes version
  labels         = each.value.labels

  # min/max are the bounds an autoscaler (Cluster Autoscaler, Karpenter) may
  # use; nothing scales the group until one is installed. If you run one,
  # add `lifecycle { ignore_changes = [scaling_config[0].desired_size] }`.
  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = local.taint_effects[taint.value.effect]
    }
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ---------------------------------------------------------------------------
# Optional extras
# ---------------------------------------------------------------------------

# EKS managed add-ons, at the default version for the cluster. Created after
# the nodes because add-ons such as coredns need somewhere to run.
resource "aws_eks_addon" "this" {
  for_each = toset(var.addons)

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.value

  depends_on = [aws_eks_node_group.this]
}

# IAM OIDC provider, needed for IAM Roles for Service Accounts (IRSA).
data "tls_certificate" "oidc" {
  count = var.enable_oidc ? 1 : 0

  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  count = var.enable_oidc ? 1 : 0

  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc[0].certificates[0].sha1_fingerprint]
}
