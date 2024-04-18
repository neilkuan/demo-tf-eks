locals {
  namespace = "kube-system"
  name = "demo-cluster"
  region = "ap-northeast-1"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
  vpc_cidr = "10.0.0.0/16"
  cluster_version = "1.29"
  tags = {
    Example    = local.name
    GithubRepo = "terraform-aws-vpc"
    GithubOrg  = "terraform-aws-modules"
  }
}

data "aws_ami" "eks_default" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amazon-eks-node-${local.cluster_version}-v*"]
  }
}

provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name = "${local.name}-vpc"
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  
  #### Keep for using AWS Load Balancer Controller ####
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
  #### Keep for using AWS Load Balancer Controller ####
  
  enable_dns_hostnames = true
  enable_dns_support   = true
  

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}

resource "aws_iam_policy" "eks_fargate_role_logging_policy" {
  name = "${local.name}-eks-fargate-role-logging-policy"
  #checkov:skip=CKV_AWS_289:No constraints for now
  #checkov:skip=CKV_AWS_290:No constraints for now
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
		"logs:CreateLogGroup",
		"logs:DescribeLogStreams",
		"logs:PutLogEvents",
        "logs:PutRetentionPolicy"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"

  create = true

  # Extend cluster security group rules
  cluster_security_group_additional_rules = {
    egress_nodes_ephemeral_ports_tcp = {
      description                = "To node 1025-65535"
      protocol                   = "tcp"
      from_port                  = 1025
      to_port                    = 65535
      type                       = "egress"
      source_node_security_group = true
    }
    ingress_nodes_ephemeral_ports_tcp = {
      description                = "Allow ingress to fargate all traffic from node"
      protocol                   = "-1"
      from_port                  = 0
      to_port                    = 0
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  # Extend node-to-node security group rules
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  node_security_group_use_name_prefix = false
  node_security_group_tags = {
    "Name" = "${local.name}-eks-worker-sg"
  }

  vpc_id  = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_name    = local.name
  cluster_version = "1.29"

  # cluster_endpoint_private_access        = true
  cluster_endpoint_public_access         = true
  #cluster_endpoint_public_access_cidrs   = []

  cluster_enabled_log_types              = []

  enable_kms_key_rotation                   = false
  attach_cluster_encryption_policy          = false
  cluster_encryption_policy_use_name_prefix = false

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns = {
      configuration_values = jsonencode({
        computeType = "Fargate"
        # Ensure that we fully utilize the minimum amount of resources that are supplied by
        # Fargate https://docs.aws.amazon.com/eks/latest/userguide/fargate-pod-configuration.html
        # Fargate adds 256 MB to each pod's memory reservation for the required Kubernetes
        # components (kubelet, kube-proxy, and containerd). Fargate rounds up to the following
        # compute configuration that most closely matches the sum of vCPU and memory requests in
        # order to ensure pods always have the resources that they need to run.
        resources = {
          limits = {
            cpu = "0.25"
            # We are targeting the smallest Task size of 512Mb, so we subtract 256Mb from the
            # request/limit to ensure we can fit within that task
            memory = "256M"
          }
          requests = {
            cpu = "0.25"
            # We are targeting the smallest Task size of 512Mb, so we subtract 256Mb from the
            # request/limit to ensure we can fit within that task
            memory = "256M"
          }
        }
      })
    }
    kube-proxy = {}
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          WARM_ENI_TARGET         = "0"
          WARM_IP_TARGET          = "2"
          MINIMUM_IP_TARGET       = "8"
          ENABLE_SUBNET_DISCOVERY = "true"
        }
      })
    }
  }
  create_cluster_security_group = true
  create_node_security_group    = true

  fargate_profiles = {
    kube-system = {
      selectors = [
        { namespace = "kube-system" }
      ]

      /**
      * https://docs.aws.amazon.com/eks/latest/userguide/fargate-logging.html
      */
      iam_role_additional_policies = {
        eks_fargate_role_logging_policy = aws_iam_policy.eks_fargate_role_logging_policy.arn
      }
    }
  }
}


data "aws_eks_cluster_auth" "eks" {
  depends_on = [module.eks.cluster_name]
  name = module.eks.cluster_name
}

data "aws_eks_cluster" "eks" {
  depends_on = [module.eks.cluster_name]
  name = "${module.eks.cluster_name}"
}

######################
# Kubernetes provider
######################
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.eks.token
  exec {
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  alias = "default"
  kubernetes {
    # config_path = "~/.kube/config"
    
    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  alias = "k8s"
  apply_retry_count      = 10
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

### Fargate use cluster_primary_security_group as default Security Group
### So add Node Security Group allow access cluster_primary_security_group.
resource "aws_security_group_rule" "cluster_primary_security_group_from_node_security_group" {
  to_port                  = -1
  from_port                = -1
  type                     = "ingress"
  security_group_id        = module.eks.cluster_primary_security_group_id
  protocol                 = "all"
  source_security_group_id = module.eks.node_security_group_id
}

################################################################################
# Karpenter
################################################################################

module "karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"

  cluster_name = module.eks.cluster_name

  irsa_namespace_service_accounts = [
    "kube-system:karpenter"
  ]

  node_iam_role_attach_cni_policy = false

  # EKS Fargate currently does not support Pod Identity
  enable_irsa            = true
  irsa_oidc_provider_arn = module.eks.oidc_provider_arn

  create_node_iam_role = true

  create_instance_profile = true

  # Used to attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    # AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
  create_access_entry = true
  tags = local.tags
}

resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  create_namespace = false
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  #   repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  #   repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart   = "karpenter"
  version = "0.35.2"
  wait    = false
  depends_on = [
    module.karpenter,
    module.eks.fargate_profiles,
    data.aws_eks_cluster_auth.eks,
    module.eks.cluster_name,
    module.eks.access_entries,
    module.eks.access_policy_associations,
  ]

  values = [
    <<-EOT
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${module.karpenter.iam_role_arn}
    controller:
      resources:
        requests:
          cpu: 900m
          memory: 1900Mi
    tolerations:
      - key: 'eks.amazonaws.com/compute-type'
        operator: Equal
        value: fargate
        effect: "NoSchedule"
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: eks.amazonaws.com/compute-type
              operator: In
              values:
              - fargate
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
        - topologyKey: kubernetes.io/hostname
          labelSelector:
            matchExpressions:
            - key: k8s-app
              operator: NotIn
              values:
              - kube-dns
            - key: app.kubernetes.io/name
              operator: NotIn
              values:
              - karpenter
          
    EOT
  ]
}

resource "kubectl_manifest" "karpenter_node_class" {
  provider   = kubectl.k8s
  apply_only = true
  yaml_body  = <<-YAML
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  amiSelectorTerms:
  - id: ${data.aws_ami.eks_default.id}
  blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      deleteOnTermination: true
      encrypted: true
      iops: 3000
      throughput: 150
      volumeSize: 50Gi
      volumeType: gp3
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required
  instanceProfile: "${module.karpenter.instance_profile_name}"
  subnetSelectorTerms:
    - tags:
        Name: "stp-vpc-pub-private-${local.region}*"
  securityGroupSelectorTerms:
    - tags:
        Name: "${local.name}-eks-worker-sg"
  tags:
    Name: "${module.eks.cluster_name}-karpenter-default"
    app: default
    karpenter.sh/discovery: ${module.eks.cluster_name}
  YAML

  depends_on = [
    module.karpenter,
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  provider   = kubectl.k8s
  apply_only = true
  yaml_body  = <<-YAML
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  limits:
    cpu: 1000
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
  template:
    metadata:
      labels:
        app: default
    spec:
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values:
          - amd64
        - key: kubernetes.io/os
          operator: In
          values:
          - linux
        - key: node.kubernetes.io/instance-type
          operator: In
          values: t3.medium
        - key: karpenter.sh/capacity-type
          operator: In
          values:
          - "spot"
  YAML

  depends_on = [
    module.karpenter,
    helm_release.karpenter,
    kubectl_manifest.karpenter_node_class
  ]
}


/**
* Fargate logging configuration
* https://docs.aws.amazon.com/eks/latest/userguide/fargate-logging.html
*/
resource "kubernetes_namespace" "aws_observability" {
  metadata {
    name = "aws-observability"
    labels = {
      "aws-observability" = "enabled"
    }
  }
}

resource "kubectl_manifest" "aws_logging" {
  provider   = kubectl.k8s
  apply_only = true
  yaml_body  = <<-YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-logging
  namespace: aws-observability
data:
  flb_log_cw: "false"  # Set to true to ship Fluent Bit process logs to CloudWatch.
  filters.conf: |
    [FILTER]
        Name parser
        Match *
        Key_name log
        Parser crio
    [FILTER]
        Name kubernetes
        Match kube.*
        Merge_Log On
        Keep_Log Off
        Buffer_Size 0
        KuMeta_Cache_TTL 300s
  output.conf: |
    [OUTPUT]
        Name cloudwatch_logs
        Match   kube.*
        region ${local.region}
        log_group_name /aws/eks/${local.name}/aws-fluentbit-logs
        log_stream_prefix fargate-
        log_stream_template $kubernetes['pod_name'].$kubernetes['container_name']
        log_retention_days 180
        auto_create_group false
  parsers.conf: |
    [PARSER]
        Name crio
        Format Regex
        Regex ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>P|F) (?<log>.*)$
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L%z
  YAML

  depends_on = [
    kubernetes_namespace.aws_observability,
  ]
}

resource "time_sleep" "wait_for_karpenter" {
  depends_on = [
    module.karpenter,
    helm_release.karpenter,
    kubectl_manifest.karpenter_node_pool,
    kubectl_manifest.karpenter_node_class
  ]
  create_duration  = "180s"
  destroy_duration = "120s"
}

###########
# BluePrint Addons
##########
module "eks_blueprints_addon" {
  depends_on = [
    time_sleep.wait_for_karpenter,
    helm_release.karpenter,
    kubectl_manifest.karpenter_node_class,
    kubectl_manifest.karpenter_node_pool,
    data.aws_eks_cluster_auth.eks,
    module.eks.cluster_name,
    module.eks.access_entries,
    module.eks.access_policy_associations,
  ]
  providers = {
    helm = helm.default
  }
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "1.16.2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    create_namespace = false
    namespace        = "kube-public"
    chart_version    = "1.7.2"
    wait             = true
    timeout          = 600
    values = [
      <<-EOT
      controllerConfig:
        featureGates:
          SubnetsClusterTagCheck: false
      clusterName: ${module.eks.cluster_name}
      nodeSelector:
        app: devops
      EOT
    ]
  }
}

/** 
* BluePrint Addons without AWS Load Balancer Controller 
*/
module "eks_blueprints_addon_other" {
  depends_on = [
  module.eks_blueprints_addon.aws_load_balancer_controller, ]
  providers = {
    helm = helm.default
  }
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "1.16.2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_metrics_server = true
  metrics_server = {
    create_namespace = false
    namespace        = "kube-public"
    wait             = false
    timeout          = 600
    values = [
      <<-EOT
      apiService:
        create: true
      nodeSelector:
        app: devops
      EOT
    ]
  }
  enable_aws_for_fluentbit = true
  aws_for_fluentbit_cw_log_group = {
    use_name_prefix = false
    retention       = 180
    skip_destroy    = false
  }
  aws_for_fluentbit = {
    create_namespace = false
    namespace        = "kube-public"
    chart_version    = "0.1.26"
    wait             = false
    timeout          = 600
    values = [
      <<-EOT
      cloudWatchLogs:
        autoCreateGroup: false
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      tolerations:
        - operator: Exists
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/os
                operator: In
                values:
                - linux
              - key: kubernetes.io/arch
                operator: In
                values:
                - amd64
                - arm64
              - key: eks.amazonaws.com/compute-type
                operator: NotIn
                values:
                - fargate
    EOT
    ]
  }
}



output "eks" {
  value = {
    "cluster_name"           = module.eks.cluster_name
    "cluster_endpoint"       = module.eks.cluster_endpoint
    "cluster_iam_role_arn"   = module.eks.cluster_iam_role_arn
  }
}