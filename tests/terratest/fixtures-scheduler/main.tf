terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
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

variable "automation_role_arn" {
  description = "ARN of the IAM role that SSM Automation will assume to perform actions."
  type        = string
}

variable "schedule_tag_key" {
  description = "Tag key used to opt resources into scheduling."
  type        = string
  default     = "Schedule"
}

# ----------------------------------------------------------------------------
# Call the scheduler module under test
# ----------------------------------------------------------------------------

module "rds_scheduler" {
  # NOTE: module source must be a literal value (can't come from vars). The Terratest
  # harness copies this fixtures folder to a temp dir, but the relative path to the
  # repo root remains the same.
  source = "../../.."

  name_prefix         = var.name_prefix
  automation_role_arn = var.automation_role_arn
  schedule_tag_key    = var.schedule_tag_key

  # This fixture exists purely to provision the production module resources.
  # We still manually trigger the association and automation document from the
  # Terratest, so runtime behaviour is validated.

  tags = {
    Fixture = "terratest"
  }
}

output "ssm_document_name" {
  value = module.rds_scheduler.ssm_document_name
}
