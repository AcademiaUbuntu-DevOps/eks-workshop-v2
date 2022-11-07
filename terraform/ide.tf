locals {
  environment_variables = <<EOT
AWS_ACCOUNT_ID=${data.aws_caller_identity.current.account_id}
AWS_DEFAULT_REGION=${data.aws_region.current.name}
EKS_CLUSTER_NAME=${module.cluster.eks_cluster_id}
EKS_DEFAULT_MNG_NAME=${split(":", module.cluster.eks_cluster_nodegroup_name)[1]}
EKS_DEFAULT_MNG_MIN=${module.cluster.eks_cluster_nodegroup_size_min}
EKS_DEFAULT_MNG_MAX=${module.cluster.eks_cluster_nodegroup_size_max}
EKS_DEFAULT_MNG_DESIRED=${module.cluster.eks_cluster_nodegroup_size_desired}
CARTS_DYNAMODB_TABLENAME=${module.cluster.cart_dynamodb_table_name}
CARTS_IAM_ROLE=${module.cluster.cart_iam_role}
ORDERS_RDS_ENDPOINT=${module.cluster.orders_rds_endpoint}
ORDERS_RDS_USERNAME=${module.cluster.orders_rds_master_username}
ORDERS_RDS_PASSWORD=${module.cluster.orders_rds_master_password}
ORDERS_RDS_DATABASE_NAME=${module.cluster.orders_rds_database_name}
ORDERS_RDS_SG_ID=${module.cluster.orders_rds_ingress_sg_id}
EFS_ID=${module.cluster.efsid}
AMP_ENDPOINT=${module.cluster.amp_endpoint}
ADOT_IAM_ROLE=${module.cluster.adot_iam_role}
EOT
}

module "ide" {
  source = "./modules/ide"

  count = var.repository_archive_location == "" ? 0 : 1

  environment_name = module.cluster.eks_cluster_id
  subnet_id        = module.cluster.public_subnet_ids[0]

  additional_cloud9_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  ]

  additional_cloud9_policies = [
    jsondecode(templatefile("${path.module}/local/iam_policy.json", {
      cluster_name = module.cluster.eks_cluster_id,
      cluster_arn  = module.cluster.eks_cluster_arn,
      nodegroup    = module.cluster.eks_cluster_nodegroup
    }))
  ]

  cloud9_user_arns = var.cloud9_user_arns

  bootstrap_script = <<EOF
aws s3 cp ${var.repository_archive_location} /tmp/repository.zip
mkdir -p /tmp/repository-archive
unzip -o -qq /tmp/repository.zip -d /tmp/repository-archive

(cd /tmp/repository-archive/environment && bash ./installer.sh)

mkdir -p /workspace
cp -R /tmp/repository-archive/environment/workspace/* /workspace
chmod +x /tmp/repository-archive/environment/bin/*
cp /tmp/repository-archive/environment/bin/* /usr/local/bin

rm -rf /tmp/repository-archive

cat << EOT > /home/ec2-user/.env
${local.environment_variables}
EOT

sudo -H -u ec2-user bash -c "mkdir -p ~/.bashrc.d"
sudo -H -u ec2-user bash -c "touch ~/.bashrc.d/dummy.bash"

if [[ ! -d "/home/ec2-user/.bashrc.d" ]]; then
  sudo -H -u ec2-user bash -c "echo 'for file in ~/.bashrc.d/*.bash; do source \"\$file\"; done' >> ~/.bashrc"
fi

sudo -H -u ec2-user bash -c "echo 'source ~/.env' > ~/.bashrc.d/env.bash"
sudo -H -u ec2-user bash -c "echo 'aws eks update-kubeconfig --name ${module.cluster.eks_cluster_id}' > ~/.bashrc.d/kubeconfig.bash"

EOF
}