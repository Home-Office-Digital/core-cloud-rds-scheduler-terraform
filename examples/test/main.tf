
################################################################################
# Test Deployment — RDS Scheduled Stop/Start
#
# Usage:
#   1. cd examples/test/
#   2. terraform init
#   3. terraform plan
#   4. terraform apply
#   5. Tag a test RDS instance/cluster with Schedule=true
#   6. Verify via SSM console or trigger manually
#   7. terraform destroy (cleanup)
################################################################################

provider "aws" {
  region = "eu-west-2"
}

locals {
  common_tags = {
    Environment  = "test"
    ManagedBy    = "terraform"
    Purpose      = "rds-scheduler-testing"
    Owner        = "core-cloud"
    cost-centre  = "1709144"
    account-code = "521835"
    portfolio-id = "CTO"
    project-id   = "CC"
    service-id   = "rds-scheduled-stop-start"
  }
}

# ------------------------------------------------------------------------------
# IAM Role
# ------------------------------------------------------------------------------

resource "aws_iam_role" "ssm_rds_scheduler" {
  name = "cc-test-ssm-rds-scheduler"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# checkov:skip=CKV_AWS_355: wildcard in role policy is for example testing only
# checkov:skip=CKV_AWS_356: wildcard in role policy is for example testing only
resource "aws_iam_role_policy" "ssm_rds_scheduler" {
  name = "rds-scheduled-stop-start"
  role = aws_iam_role.ssm_rds_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowStopStartTaggedResources"
        Effect = "Allow"
        Action = [
          "rds:StopDBCluster",
          "rds:StartDBCluster",
          "rds:StopDBInstance",
          "rds:StartDBInstance"
        ]
        Resource = [
          "arn:aws:rds:*:*:cluster:*",
          "arn:aws:rds:*:*:db:*"
        ]
        Condition = {
          StringLike = { "aws:ResourceTag/Schedule" = "*" }
        }
      },
      {
        Sid    = "AllowDescribeForDiscovery"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBClusters",
          "rds:DescribeDBInstances",
          "rds:ListTagsForResource"
        ]
        Resource = "*"
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# Module under test
# ------------------------------------------------------------------------------

module "rds_scheduled_stop_start" {
  source = "../../"

  name_prefix         = "cc-test-rds-scheduler"
  automation_role_arn = aws_iam_role.ssm_rds_scheduler.arn
  schedule_tag_key    = "Schedule"

  # Defaults: all RDS up 8am-6pm UTC weekdays
  # start_rds_hour       = 8   (default)
  # stop_rds_hour        = 18  (default)
  # start_aurora_hour    = 8   (default)
  # stop_aurora_hour     = 18  (default)

  tags = local.common_tags
}

# module "rds_scheduled_stop_start" {
#   count = local.hasFeature.enableRDSScheduledStopStart ? 1 : 0

#   source = "../modules/rds-scheduled-stop-start"

#   name_prefix        = "cc-rds-scheduler"
#   automation_role_arn = aws_iam_role.ssm_rds_scheduled_stop_start[0].arn
#   schedule_tag_key   = "Schedule"

#   # Defaults: all RDS up 8am-6pm UTC weekdays
#   # start_rds_hour       = 8   (default)
#   # stop_rds_hour        = 18  (default)
#   # start_aurora_hour    = 8   (default)
#   # stop_aurora_hour     = 18  (default)

#   tags = merge(local.cc_common_tags)
# }
