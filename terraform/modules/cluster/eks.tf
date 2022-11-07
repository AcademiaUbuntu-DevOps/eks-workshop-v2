locals {
  default_mng_min  = 2
  default_mng_max  = 6
  default_mng_size = 2
}

data "aws_ssm_parameter" "eks_optimized_ami" {
  name = "/aws/service/eks/optimized-ami/${local.cluster_version}/amazon-linux-2/recommended/image_id"
}

module "eks-blueprints" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.10.0"

  tags = local.tags

  vpc_id             = module.aws_vpc.vpc_id
  private_subnet_ids = local.private_subnet_ids
  public_subnet_ids  = module.aws_vpc.public_subnets

  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  cluster_kms_key_additional_admin_arns = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]

  map_roles = var.map_roles

  node_security_group_additional_rules = {
    # Extend node-to-node security group rules. Recommended and required for the Add-ons
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Recommended outbound traffic for Node groups
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }

    # Allows Control Plane Nodes to talk to Worker nodes on Karpenter ports.
    # This can be extended further to specific port based on the requirement for others Add-on e.g., metrics-server 4443, spark-operator 8080, etc.
    # Change this according to your security requirements if needed
    ingress_nodes_karpenter_port = {
      description                   = "Cluster API to Nodegroup for Karpenter"
      protocol                      = "tcp"
      from_port                     = 8443
      to_port                       = 8443
      type                          = "ingress"
      source_cluster_security_group = true
    }

    ingress_nodes_load_balancer_controller_port = {
      description                   = "Cluster API to Nodegroup for Load Balancer Controller"
      protocol                      = "tcp"
      from_port                     = 9443
      to_port                       = 9443
      type                          = "ingress"
      source_cluster_security_group = true
    }
    
    ingress_nodes_metric_server_port = {
      description                   = "Cluster API to Nodegroup for Metric Server"
      protocol                      = "tcp"
      from_port                     = 4443
      to_port                       = 4443
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  # Add karpenter.sh/discovery tag so that we can use this as securityGroupSelector in karpenter provisioner
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  managed_node_groups = {
    mg_5 = {
      node_group_name = "managed-ondemand"
      instance_types  = ["m5.large"]
      subnet_ids      = local.private_subnet_ids
      min_size        = local.default_mng_min
      max_size        = local.default_mng_max
      desired_size    = local.default_mng_size

      custom_ami_id   = data.aws_ssm_parameter.eks_optimized_ami.value
      
      create_launch_template = true
      launch_template_os = "amazonlinux2eks"

      pre_userdata =  <<-EOT
        MAX_PODS=$(/etc/eks/max-pods-calculator.sh --instance-type-from-imds --cni-version ${trimprefix(data.aws_eks_addon_version.latest["vpc-cni"].version, "v")} --cni-prefix-delegation-enabled)
      EOT

      kubelet_extra_args   = "--max-pods=$${MAX_PODS}"
      bootstrap_extra_args = "--use-max-pods false"

      k8s_labels = {
        workshop-default = "yes"
      }
    }

    system = {
      node_group_name = "managed-system"
      instance_types  = ["m5.large"]
      subnet_ids      = slice(local.private_subnet_ids, 0, 1)
      min_size        = 1
      max_size        = 2
      desired_size    = 1

      custom_ami_id   = data.aws_ssm_parameter.eks_optimized_ami.value
      
      create_launch_template = true
      launch_template_os = "amazonlinux2eks"

      pre_userdata =  <<-EOT
        MAX_PODS=$(/etc/eks/max-pods-calculator.sh --instance-type-from-imds --cni-version ${trimprefix(data.aws_eks_addon_version.latest["vpc-cni"].version, "v")} --cni-prefix-delegation-enabled)
      EOT

      kubelet_extra_args   = "--max-pods=$${MAX_PODS}"
      bootstrap_extra_args = "--use-max-pods false"

      k8s_taints = [{ key = "systemComponent", value = "true", effect = "NO_SCHEDULE" }]

      k8s_labels = {
        workshop-system = "yes"
      }
    }
  }

  fargate_profiles = {
    checkout_profile = {
      fargate_profile_name = "checkout-profile"
      fargate_profile_namespaces = [{
        namespace = "checkout"
        k8s_labels = {
          fargate = "yes"
        }
      }]
      subnet_ids = local.private_subnet_ids
    }
  }
}

# Build kubeconfig for use with null resource to modify aws-node daemonset
locals {
  kubeconfig = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = "terraform"
    clusters = [{
      name = module.eks-blueprints.eks_cluster_id
      cluster = {
        certificate-authority-data = module.eks-blueprints.eks_cluster_certificate_authority_data
        server                     = module.eks-blueprints.eks_cluster_endpoint
      }
    }]
    contexts = [{
      name = "terraform"
      context = {
        cluster = module.eks-blueprints.eks_cluster_id
        user    = "terraform"
      }
    }]
    users = [{
      name = "terraform"
      user = {
        token = data.aws_eks_cluster_auth.cluster.token
      }
    }]
  })
}

resource "null_resource" "kubectl_set_env" {
  triggers = {}

  depends_on = [
    module.eks-blueprints
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = base64encode(local.kubeconfig)
    }

    # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
    command = <<-EOT
      kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true --kubeconfig <(echo $KUBECONFIG | base64 --decode)
      kubectl set env daemonset aws-node -n kube-system WARM_PREFIX_TARGET=1 --kubeconfig <(echo $KUBECONFIG | base64 --decode)
    EOT
  }
}
