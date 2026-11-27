variable "name_prefix" {
  description = "Prefix for all resource names. Must be lowercase alphanumeric with hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens."
  }
}

variable "automation_role_arn" {
  description = "ARN of the IAM role that SSM Automation will assume to perform actions."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z0-9-]*:iam::\\d{12}:role/.+$", var.automation_role_arn))
    error_message = "automation_role_arn must be a valid IAM role ARN."
  }
}

variable "schedule_tag_key" {
  description = "Tag key used to identify RDS resources that opt-in to scheduling."
  type        = string
  default     = "Schedule"

  validation {
    condition     = length(var.schedule_tag_key) > 0
    error_message = "schedule_tag_key must not be empty."
  }
}

# ------------------------------------------------------------------------------
# Schedules — RDS Instances
#
# SSM association cron is built in main.tf as:
#   cron(<minute> <hour> ? * <DAY> *)
# The day-of-week is handled by for_each (MON-FRI individually).
# Only hour and minute are configurable here.
# ------------------------------------------------------------------------------

variable "start_rds_hour" {
  description = "UTC hour (0-23) to start RDS instances on weekdays."
  type        = number
  default     = 8

  validation {
    condition     = var.start_rds_hour >= 0 && var.start_rds_hour <= 23
    error_message = "start_rds_hour must be between 0 and 23."
  }
}

variable "start_rds_minute" {
  description = "UTC minute (0-59) to start RDS instances on weekdays."
  type        = number
  default     = 0

  validation {
    condition     = var.start_rds_minute >= 0 && var.start_rds_minute <= 59
    error_message = "start_rds_minute must be between 0 and 59."
  }
}

variable "stop_rds_hour" {
  description = "UTC hour (0-23) to stop RDS instances on weekdays."
  type        = number
  default     = 18

  validation {
    condition     = var.stop_rds_hour >= 0 && var.stop_rds_hour <= 23
    error_message = "stop_rds_hour must be between 0 and 23."
  }
}

variable "stop_rds_minute" {
  description = "UTC minute (0-59) to stop RDS instances on weekdays."
  type        = number
  default     = 0

  validation {
    condition     = var.stop_rds_minute >= 0 && var.stop_rds_minute <= 59
    error_message = "stop_rds_minute must be between 0 and 59."
  }
}

# ------------------------------------------------------------------------------
# Schedules — Aurora Clusters
# Same window as instances: all RDS up 8am–6pm UTC.
# ------------------------------------------------------------------------------

variable "start_aurora_hour" {
  description = "UTC hour (0-23) to start Aurora clusters on weekdays."
  type        = number
  default     = 8

  validation {
    condition     = var.start_aurora_hour >= 0 && var.start_aurora_hour <= 23
    error_message = "start_aurora_hour must be between 0 and 23."
  }
}

variable "start_aurora_minute" {
  description = "UTC minute (0-59) to start Aurora clusters on weekdays."
  type        = number
  default     = 0

  validation {
    condition     = var.start_aurora_minute >= 0 && var.start_aurora_minute <= 59
    error_message = "start_aurora_minute must be between 0 and 59."
  }
}

variable "stop_aurora_hour" {
  description = "UTC hour (0-23) to stop Aurora clusters on weekdays."
  type        = number
  default     = 18

  validation {
    condition     = var.stop_aurora_hour >= 0 && var.stop_aurora_hour <= 23
    error_message = "stop_aurora_hour must be between 0 and 23."
  }
}

variable "stop_aurora_minute" {
  description = "UTC minute (0-59) to stop Aurora clusters on weekdays."
  type        = number
  default     = 0

  validation {
    condition     = var.stop_aurora_minute >= 0 && var.stop_aurora_minute <= 59
    error_message = "stop_aurora_minute must be between 0 and 59."
  }
}

variable "tags" {
  description = "Tags to apply to resources created by this module."
  type        = map(string)
  default     = {}
}

variable "global_tags" {
  type        = map(string)
  description = "Base tags sourced from the GLOBAL_TAGS variable (JSON)."

  validation {
    condition = try(alltrue([
      for key in [
        "cost-centre", "account-code", "portfolio-id", "project-id",
        "service-id", "owner-business", "budget-holder", "source-repo",
      ] : trimspace(var.global_tags[key]) != ""
    ]), false)
    error_message = "global_tags must provide non-empty values for all required audit tags except environment-type, which is set by the module."
  }
}
