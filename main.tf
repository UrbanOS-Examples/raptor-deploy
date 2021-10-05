provider "aws" {
  version = "~> 3.0"
  region  = var.region

  assume_role {
    role_arn = var.role_arn
  }
}

terraform {
  backend "s3" {
    key     = "discovery-api"
    encrypt = true
  }
}

provider "aws" {
  alias   = "alm"
  version = "~> 3.0"
  region  = var.alm_region

  assume_role {
    role_arn = var.alm_role_arn
  }
}

data "terraform_remote_state" "alm_remote_state" {
  backend   = "s3"
  workspace = var.alm_workspace

  config = {
    bucket   = var.alm_state_bucket_name
    key      = "alm"
    region   = var.alm_region
    role_arn = var.alm_role_arn
  }
}

data "terraform_remote_state" "env_remote_state" {
  backend   = "s3"
  workspace = terraform.workspace

  config = {
    bucket   = var.alm_state_bucket_name
    key      = "operating-system"
    region   = var.alm_region
    role_arn = var.alm_role_arn
  }
}

data "aws_secretsmanager_secret_version" "ldap_bind_password" {
  provider  = aws.alm
  secret_id = data.terraform_remote_state.alm_remote_state.outputs.bind_user_password_secret_id
}

resource "random_string" "disovery_api_presign_key" {
  length           = 64
  special          = true
  override_special = "/@$#*"
}

resource "random_string" "disovery_api_guardian_key" {
  length           = 64
  special          = true
  override_special = "/@$#*"
}

resource "local_file" "kubeconfig" {
  filename = "${path.module}/outputs/kubeconfig"
  content  = data.terraform_remote_state.env_remote_state.outputs.eks_cluster_kubeconfig
}

resource "aws_iam_access_key" "discovery_api" {
  user = data.terraform_remote_state.env_remote_state.outputs.discovery_api_aws_user_name
}

data "aws_secretsmanager_secret_version" "discovery_api_user_password" {
  provider  = aws.alm
  secret_id = data.terraform_remote_state.alm_remote_state.outputs.discovery_api_user_password_secret_id
}

resource "local_file" "helm_vars" {
  filename = "${path.module}/outputs/${terraform.workspace}.yaml"

  content = <<EOF
environment: "${terraform.workspace}"
global:
  ingress:
    annotations:
      kubernetes.io/ingress.class: alb
      alb.ingress.kubernetes.io/ssl-policy: "ELBSecurityPolicy-TLS-1-2-2017-01"
      alb.ingress.kubernetes.io/healthcheck-path: /healthcheck
      alb.ingress.kubernetes.io/scheme: "${var.is_internal ? "internal" : "internet-facing"}"
      alb.ingress.kubernetes.io/subnets: "${join(
    ",",
    data.terraform_remote_state.env_remote_state.outputs.public_subnets,
  )}"
      alb.ingress.kubernetes.io/security-groups: "${data.terraform_remote_state.env_remote_state.outputs.allow_all_security_group}"
      alb.ingress.kubernetes.io/certificate-arn: "${data.terraform_remote_state.env_remote_state.outputs.tls_certificate_arn},${data.terraform_remote_state.env_remote_state.outputs.root_tls_certificate_arn}"
      alb.ingress.kubernetes.io/tags: scos.delete.on.teardown=true
      alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=4000
      alb.ingress.kubernetes.io/actions.redirect: '{"Type": "redirect", "RedirectConfig":{"Protocol": "HTTPS", "Port": "443", "StatusCode": "HTTP_301"}}'
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
      alb.ingress.kubernetes.io/wafv2-acl-arn: "${data.terraform_remote_state.env_remote_state.outputs.eks_cluster_waf_acl_arn}"
    dnsZone: "${data.terraform_remote_state.env_remote_state.outputs.internal_dns_zone_name}"
    rootDnsZone: "${data.terraform_remote_state.env_remote_state.outputs.root_dns_zone_name}"
    port: 80
postgres:
  host: "${module.discovery_rds.address}"
  port: "${module.discovery_rds.port}"
  dbname: "${module.discovery_rds.name}"
  user: "${module.discovery_rds.username}"
  password: "${data.aws_secretsmanager_secret_version.discovery_rds_password.secret_string}"
elasticsearch:
  host: "${data.terraform_remote_state.env_remote_state.outputs.elasticsearch_endpoint}"
aws:
  accessKeyId: "${aws_iam_access_key.discovery_api.id}"
  accessKeySecret: "${aws_iam_access_key.discovery_api.secret}"
secrets:
  guardianSecretKey: "${random_string.disovery_api_guardian_key.result}"
  discoveryApiPresignKey : "${random_string.disovery_api_presign_key.result}"
EOF

}

resource "local_file" "auth0_vars" {
  filename = "${path.module}/outputs/${terraform.workspace}-auth0.yaml"

  content  = <<EOF
  global:
    auth:
      jwt_issuer: "https://${var.auth0_tenant}.auth0.com/"
      auth0_domain: "${var.auth0_tenant}.auth0.com"
  auth:
    jwks_endpoint: "https://${var.auth0_tenant}.auth0.com/.well-known/jwks.json"
    user_info_endpoint: "https://${var.auth0_tenant}.auth0.com/userinfo"
    client_id: "${var.auth0_client_id}"
    redirect_base_url: "${local.auth0_redirect_url}"
  EOF
}

resource "null_resource" "helm_deploy" {
  provisioner "local-exec" {
    command = <<EOF
set -x

export KUBECONFIG=${local_file.kubeconfig.filename}

export AWS_DEFAULT_REGION=us-east-2
discovery_secrets="$(kubectl -n discovery get secrets -o jsonpath='{.items[*].metadata.name}')"

create_secret() {
    local _secret_name="$1"
    local _secret="$2"

    if echo "$discovery_secrets" | grep "$_secret_name"
    then
        echo "Secret '$_secret_name' already exists"
    else
        kubectl -n discovery create secret generic "$_secret_name" --from-literal="$_secret"
    fi
}

set +x
create_secret "ldap" "password=${data.aws_secretsmanager_secret_version.ldap_bind_password.secret_string}"
set -x
helm repo add scdp https://datastillery.github.io/charts
helm repo update
helm upgrade --install discovery-api scdp/discovery-api --namespace=discovery \
    --version 1.2.0 \
    --values ${local_file.helm_vars.filename} \
    --values=discovery-api-base.yaml \
    --values=${local_file.auth0_vars.filename} \
    --set image.pullPolicy=${var.image_pull_policy} \
    ${var.extra_helm_args}
EOF

  }

  triggers = {
    # Triggers a list of values that, when changed, will cause the resource to be recreated
    # ${uuid()} will always be different thus always executing above local-exec
    hack_that_always_forces_null_resources_to_execute = uuid()
  }
}

module "discovery_rds" {
  source = "git@github.com:SmartColumbusOS/scos-tf-rds?ref=2.0.0"

  vers                     = "10.15"
  prefix                   = "${terraform.workspace}-discovery-postgres"
  identifier               = "${terraform.workspace}-discovery"
  database_name            = "discovery"
  type                     = "postgres"
  attached_vpc_id          = data.terraform_remote_state.env_remote_state.outputs.vpc_id
  attached_subnet_ids      = data.terraform_remote_state.env_remote_state.outputs.private_subnets
  attached_security_groups = [data.terraform_remote_state.env_remote_state.outputs.chatter_sg_id]
  instance_class           = var.postgres_instance_class
}

data "aws_secretsmanager_secret_version" "discovery_rds_password" {
  secret_id = module.discovery_rds.password_secret_id
}

locals {
  auth0_redirect_url = coalesce(
    var.auth0_redirect_url,
    "https://data.${terraform.workspace}.sandbox.internal.smartcolumbusos.com"
  )
}

variable "auth0_tenant" {
  description = "Auth0 tenant name for authentication"
  default     = "smartcolumbusos-demo"
}

variable "auth0_client_id" {
  description = "Auth0 client ID for authentication"
}

variable "auth0_redirect_url" {
  description = "(Optional) Redirect URL for auth0 calls.  When left unspecified the value is built as sandbox using the workspace"
}

variable "is_internal" {
  description = "Should the ALBs be internal facing"
  default     = false
}

variable "region" {
  description = "Region of operating system resources"
  default     = "us-west-2"
}

variable "role_arn" {
  description = "The ARN for the assume role for ALM access"
  default     = "arn:aws:iam::199837183662:role/jenkins_role"
}

variable "alm_role_arn" {
  description = "The ARN for the assume role for ALM access"
  default     = "arn:aws:iam::199837183662:role/jenkins_role"
}

variable "alm_state_bucket_name" {
  description = "The name of the S3 state bucket for ALM"
  default     = "scos-alm-terraform-state"
}

variable "alm_region" {
  description = "Region of ALM resources"
  default     = "us-east-2"
}

variable "alm_workspace" {
  description = "The workspace to pull ALM outputs from"
  default     = "alm"
}

variable "extra_helm_args" {
  description = "Optional helm arguments that can be overridden at runtime"
  default     = ""
}

variable "image_pull_policy" {
  description = "Set the image pull policy for the discovery_api pod"
  default     = "IfNotPresent"
}

variable "postgres_instance_class" {
  description = "The size of the discovery rds instance"
  default     = "db.t3.small"
}

