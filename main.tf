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

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4"

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
  eks_managed_node_groups = {
    complete = {
      name            = "complete-eks-mng"
      subnet_ids = module.vpc.private_subnets
      min_size     = 1
      max_size     = 2
      desired_size = 1

      ami_id                     = data.aws_ami.eks_default.image_id

      capacity_type        = "SPOT"
      force_update_version = true
      instance_types       = ["m6i.large", "m5.large", "m5n.large", "m5zn.large"]
      labels = {
        GithubRepo = "terraform-aws-eks"
        GithubOrg  = "terraform-aws-modules"
      }

      description = "EKS managed node group example launch template"

      ebs_optimized           = true
      disable_api_termination = false
      enable_monitoring       = true
      enable_bootstrap_user_data = true

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 75
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 150
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
        # instance_metadata_tags      = "disabled"
      }

      create_iam_role          = true
      iam_role_name            = "eks-managed-node-group-complete-example"
      iam_role_use_name_prefix = false
      iam_role_description     = "EKS managed node group complete example role"
      iam_role_tags = {
        Purpose = "Protector of the kubelet"
      }
      iam_role_additional_policies = {
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }

      launch_template_tags = {
        # enable discovery of autoscaling groups by cluster-autoscaler
        "k8s.io/cluster-autoscaler/enabled" : true,
        "k8s.io/cluster-autoscaler/${local.name}" : "owned",
      }

      tags = {
        ExtraTag = "EKS managed node group complete example"
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
  kubernetes {
    # config_path = "~/.kube/config"

    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.eks.token
    exec {
      api_version = "client.authentication.k8s.io/v1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

module "eks_blueprints_addon" {
  depends_on = [
    data.aws_eks_cluster_auth.eks,
    module.eks.cluster_name,
    module.eks.access_entries,
    module.eks.access_policy_associations,
    module.eks.eks_managed_node_groups,
    module.vpc
  ]
  providers = {
     helm = helm
  }
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  eks_addons = {
    # aws-ebs-csi-driver = {
    #   most_recent = true
    # }
    # aws-efs-csi-driver = {
    #   most_recent = true
    # }
    coredns = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
  }

  enable_aws_load_balancer_controller    = true
  aws_load_balancer_controller = {
    create_namespace = false
    namespace        = local.namespace
    set = [
      {
        name = "controllerConfig.featureGates.SubnetsClusterTagCheck"
        value = false
      },
      {
        name  = "clusterName"
        value = module.eks.cluster_name
      }
    ]
  }
  enable_cluster_autoscaler              = true
  cluster_autoscaler = {
    create_namespace = false
    namespace        = local.namespace
    set = [
      {
        name  = "podAnnotations.cluster-autoscaler\\.kubernetes\\.io/safe-to-evict"
        type  = "string"
        value = "false"
      }
    ]
  }
  enable_metrics_server                  = true
  metrics_server = {
    create_namespace = false
    namespace        = local.namespace
  }
  enable_aws_for_fluentbit               = true
  aws_for_fluentbit_cw_log_group = {
    use_name_prefix = false
  }
  aws_for_fluentbit = {
    create_namespace = false
    namespace        = local.namespace
    set = [
      {
        name  = "cloudWatchLogs.autoCreateGroup"
        value = false
      },
      {
        name  = "hostNetwork"
        value = true
      },
      {
        name  = "dnsPolicy"
        value = "ClusterFirstWithHostNet"
      },
      {
        name  = "tolerations[0].operator"
        value = "Exists"
      }
    ]
  }
  # enable_external_dns            = true
  # external_dns_route53_zone_arns = ["*"]
  # external_dns =  {
  #   chart        = "external-dns"
  #   chart_version= var.external_dns_chart_version
  #   repository   = "https://charts.bitnami.com/bitnami"
  #   namespace    = local.namespace
  #   set = [
  #     {
  #       name = "provider"
  #       value = "aws"
  #     },
  #     {
  #       name = "domainFilters[0]"
  #       value = var.domain
  #     },
  #     {
  #       name = "txtOwnerId"
  #       value = "External-DNS-4-BEAPP"
  #     },
  #     {
  #       name = "txtPrefix"
  #       value = "txt-"
  #     },
  #     {
  #       name = "metrics.enabled"
  #       value = true
  #     },
  #     {
  #       name = "aws.zoneType"
  #       value = "public"
  #     },
  #     {
  #       name = "aws.preferCNAME"
  #       value = true
  #     }
  #   ]
  # }
}

output "eks" {
  value = {
    "cluster_name"           = module.eks.cluster_name
    "cluster_endpoint"       = module.eks.cluster_endpoint
    "cluster_iam_role_arn"   = module.eks.cluster_iam_role_arn
  }
}