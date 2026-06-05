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

# Note: This fixture intentionally avoids creating a customer-managed KMS key and
# custom parameter groups. Those add complexity and can significantly slow down
# provision/destroy. For a disposable Terratest DB, AWS-managed encryption and
# default parameter groups are sufficient.

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
  # checkov:skip=CKV_AWS_129:Terratest fixture is disposable; deletion protection breaks automated teardown.
  # checkov:skip=CKV_AWS_118:Enhanced monitoring requires a monitoring IAM role which can't be created in this org account (SCP); monitoring is intentionally disabled for fixture.
  # checkov:skip=CKV2_AWS_30:Query logging via a custom parameter group causes engine family mismatches across org accounts; fixture relies on defaults.
  identifier                   = "${var.name_prefix}-rds-${random_id.suffix.hex}"
  engine                       = "postgres"
  instance_class               = "db.t3.micro"
  allocated_storage            = 20
  storage_type                 = "gp3"
  publicly_accessible          = false
  db_subnet_group_name         = aws_db_subnet_group.this.name
  vpc_security_group_ids       = [aws_security_group.db.id]
  skip_final_snapshot          = true
  deletion_protection          = false
  apply_immediately            = true
  multi_az                     = false
  backup_retention_period      = 1
  auto_minor_version_upgrade   = true
  copy_tags_to_snapshot        = true
  storage_encrypted            = true
  performance_insights_enabled = false
  # Enhanced monitoring requires an IAM role (MonitoringRoleARN), which may be blocked by org SCPs.
  monitoring_interval = 0
  # Note: IAM auth isn't supported for all engines/versions; checkov expects it for RDS.
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]
  # Avoid DBParameterGroupFamily mismatches across org accounts/engine versions.
  # (Default parameter group is fine for this disposable fixture.)
  # parameter_group_name                = aws_db_parameter_group.postgres.name

  # Minimal credentials for a disposable test instance.
  username = "testuser"
  password = "TestPassword123!"

  tags = merge(local.tags, {
    Name    = "${var.name_prefix}-rds-${random_id.suffix.hex}"
    Fixture = "terratest"
  })
}

resource "aws_rds_cluster" "aurora" {
  # checkov:skip=CKV_AWS_162:Terratest fixture is disposable; deletion protection breaks automated teardown.
  # checkov:skip=CKV_AWS_287:AWS Backup plan resources require IAM role creation which is denied by org SCP; fixture uses native RDS backups only.
  # checkov:skip=CKV2_AWS_29:Query logging via a custom parameter group causes engine family mismatches across org accounts; fixture relies on defaults.
  cluster_identifier                  = "${var.name_prefix}-aurora-${random_id.suffix.hex}"
  engine                              = "aurora-postgresql"
  master_username                     = "clusteradmin"
  master_password                     = "TestPassword123!"
  db_subnet_group_name                = aws_db_subnet_group.this.name
  vpc_security_group_ids              = [aws_security_group.db.id]
  skip_final_snapshot                 = true
  deletion_protection                 = false
  backup_retention_period             = 1
  preferred_backup_window             = "03:00-04:00"
  preferred_maintenance_window        = "sun:05:00-sun:06:00"
  apply_immediately                   = true
  storage_encrypted                   = true
  copy_tags_to_snapshot               = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  # Avoid DBParameterGroupFamily mismatches across org accounts/engine versions.
  # (Default parameter group is fine for this disposable fixture.)
  # db_cluster_parameter_group_name     = aws_rds_cluster_parameter_group.aurora_postgres.name

  tags = merge(local.tags, {
    Name    = "${var.name_prefix}-aurora-${random_id.suffix.hex}"
    Fixture = "terratest"
  })
}

resource "aws_rds_cluster_instance" "aurora_writer" {
  # checkov:skip=CKV_AWS_118:Enhanced monitoring requires a monitoring IAM role which can't be created in this org account (SCP); monitoring is intentionally disabled for fixture.
  identifier                   = "${var.name_prefix}-aurora-w-${random_id.suffix.hex}"
  cluster_identifier           = aws_rds_cluster.aurora.id
  instance_class               = "db.t3.medium"
  engine                       = aws_rds_cluster.aurora.engine
  engine_version               = aws_rds_cluster.aurora.engine_version
  publicly_accessible          = false
  auto_minor_version_upgrade   = true
  performance_insights_enabled = false
  # Enhanced monitoring requires an IAM role (MonitoringRoleARN), which may be blocked by org SCPs.
  monitoring_interval = 0

  tags = merge(local.tags, {
    Name    = "${var.name_prefix}-aurora-w-${random_id.suffix.hex}"
    Fixture = "terratest"
  })
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
