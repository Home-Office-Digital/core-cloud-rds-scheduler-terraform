terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

provider "aws" {
  # Region is expected to be set by the Terratest harness via env (AWS_REGION/AWS_DEFAULT_REGION)
}

variable "name_prefix" {
  description = "Prefix for names in this fixture."
  type        = string
}

variable "schedule_tag_key" {
  description = "Tag key used to opt resources into scheduling."
  type        = string
  default     = "Schedule"
}

locals {
  schedule_tag_value = "true"
  tags = {
    (var.schedule_tag_key) = local.schedule_tag_value
  }
}

resource "random_id" "suffix" {
  byte_length = 3
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kms" {
  statement {
    sid     = "EnableIAMUserPermissions"
    effect  = "Allow"
    actions = ["kms:*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    resources = ["*"]
  }
}

resource "aws_kms_key" "this" {
  description             = "KMS key for Terratest RDS/Aurora fixture encryption (storage/PI)."
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_db_parameter_group" "postgres" {
  name   = "${var.name_prefix}-pg-${random_id.suffix.hex}"
  family = "postgres15"

  parameter {
    name  = "log_statement"
    value = "all"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "0"
  }

  # Enforce TLS for client connections (Checkov: encryption in transit).
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_rds_cluster_parameter_group" "aurora_postgres" {
  name   = "${var.name_prefix}-aurora-pg-${random_id.suffix.hex}"
  family = "aurora-postgresql15"

  parameter {
    name  = "log_statement"
    value = "all"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "0"
  }

  # Enforce TLS for client connections (Checkov: encryption in transit).
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

# ----------------------------------------------------------------------------
# Networking (reuse existing VPC/subnets due to SCP constraints)
# ----------------------------------------------------------------------------

data "aws_vpcs" "all" {}

data "aws_vpc" "selected" {
  id = data.aws_vpcs.all.ids[0]
}


data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-dbsubnet-${random_id.suffix.hex}"
  subnet_ids = slice(data.aws_subnets.selected.ids, 0, 2)

  tags = {
    Name = "${var.name_prefix}-dbsubnet-${random_id.suffix.hex}"
  }
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg-${random_id.suffix.hex}"
  description = "DB sg (no inbound; fixture does not need connectivity)"
  vpc_id      = data.aws_vpc.selected.id

  egress {
    description = "Allow Postgres egress (test fixture; no inbound rules)."
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ----------------------------------------------------------------------------
# Test resources
# ----------------------------------------------------------------------------

resource "aws_db_instance" "rds" {
  identifier                      = "${var.name_prefix}-rds-${random_id.suffix.hex}"
  engine                          = "postgres"
  instance_class                  = "db.t3.micro"
  allocated_storage               = 20
  storage_type                    = "gp3"
  publicly_accessible             = false
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  skip_final_snapshot             = true
  deletion_protection             = true
  apply_immediately               = true
  multi_az                        = true
  backup_retention_period         = 1
  auto_minor_version_upgrade      = true
  copy_tags_to_snapshot           = true
  storage_encrypted               = true
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.this.arn
  monitoring_interval             = 60
  # Note: IAM auth isn't supported for all engines/versions; checkov expects it for RDS.
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]
  parameter_group_name                = aws_db_parameter_group.postgres.name

  # Minimal credentials for a disposable test instance.
  username = "testuser"
  password = "TestPassword123!"

  tags = merge(local.tags, {
    Name    = "${var.name_prefix}-rds-${random_id.suffix.hex}"
    Fixture = "terratest"
  })
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier                  = "${var.name_prefix}-aurora-${random_id.suffix.hex}"
  engine                              = "aurora-postgresql"
  master_username                     = "clusteradmin"
  master_password                     = "TestPassword123!"
  db_subnet_group_name                = aws_db_subnet_group.this.name
  vpc_security_group_ids              = [aws_security_group.db.id]
  skip_final_snapshot                 = true
  deletion_protection                 = true
  backup_retention_period             = 1
  preferred_backup_window             = "03:00-04:00"
  preferred_maintenance_window        = "sun:05:00-sun:06:00"
  apply_immediately                   = true
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.this.arn
  copy_tags_to_snapshot               = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  db_cluster_parameter_group_name     = aws_rds_cluster_parameter_group.aurora_postgres.name

  tags = merge(local.tags, {
    Name    = "${var.name_prefix}-aurora-${random_id.suffix.hex}"
    Fixture = "terratest"
  })
}

resource "aws_rds_cluster_instance" "aurora_writer" {
  identifier                      = "${var.name_prefix}-aurora-w-${random_id.suffix.hex}"
  cluster_identifier              = aws_rds_cluster.aurora.id
  instance_class                  = "db.t3.medium"
  engine                          = aws_rds_cluster.aurora.engine
  engine_version                  = aws_rds_cluster.aurora.engine_version
  publicly_accessible             = false
  auto_minor_version_upgrade      = true
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.this.arn
  monitoring_interval             = 60

  tags = merge(local.tags, {
    Name    = "${var.name_prefix}-aurora-w-${random_id.suffix.hex}"
    Fixture = "terratest"
  })
}

resource "aws_backup_vault" "this" {
  name        = "${var.name_prefix}-vault-${random_id.suffix.hex}"
  kms_key_arn = aws_kms_key.this.arn
}

resource "aws_backup_plan" "this" {
  name = "${var.name_prefix}-plan-${random_id.suffix.hex}"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 5 * * ? *)"

    lifecycle {
      # Keep minimal retention for a disposable integration-test fixture.
      delete_after = 1
    }
  }
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "backup" {
  name_prefix        = "${var.name_prefix}-backup-"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "aurora" {
  name         = "aurora"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [
    aws_rds_cluster.aurora.arn,
  ]

  # Terraform doesn't purge AWS Backup recovery points on destroy; make teardown clean.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -euo pipefail
      if ! command -v aws >/dev/null 2>&1; then
        echo "aws CLI not available; skipping recovery point purge" >&2
        exit 0
      fi

      VAULT_NAME="${aws_backup_vault.this.name}"
      # Delete recovery points created by this fixture's backup plan.
      RECOVERY_POINTS=$(aws backup list-recovery-points-by-backup-vault \
        --backup-vault-name "$VAULT_NAME" \
        --query "RecoveryPoints[?CreatedBy.BackupPlanId=='${aws_backup_plan.this.id}'].RecoveryPointArn" \
        --output text || true)

      if [ -z "$RECOVERY_POINTS" ] || [ "$RECOVERY_POINTS" = "None" ]; then
        exit 0
      fi

      for ARN in $RECOVERY_POINTS; do
        aws backup delete-recovery-point --backup-vault-name "$VAULT_NAME" --recovery-point-arn "$ARN" || true
      done
    EOT
  }
}

output "name_prefix" {
  value = var.name_prefix
}

output "aurora_cluster_id" {
  value = aws_rds_cluster.aurora.id
}

output "aurora_cluster_instance_id" {
  value = aws_rds_cluster_instance.aurora_writer.id
}
