################################################################################
# RDS Scheduled Stop/Start Module
#
# Uses AWS SSM State Manager to stop/start RDS instances and Aurora clusters
# on a schedule. Resources opt-in by having a "Schedule" tag.
#
# SSM associations only support single days (e.g. MON), not ranges (MON-FRI).
# Workaround: one association per weekday via for_each.
#
#
# - RDS Instances: Uses AWS managed documents (AWS-StartRdsInstance/AWS-StopRdsInstance)
# - Aurora Clusters: Uses a custom SSM Automation Document (clusters can't be
#   targeted by tag natively)
# Dummy line to trigger
################################################################################

locals {
  weekdays = toset(["MON", "TUE", "WED", "THU", "FRI"])
}

# ------------------------------------------------------------------------------
# SSM Associations — RDS Instances (AWS Managed Documents)
# One association per weekday.
# ------------------------------------------------------------------------------

resource "aws_ssm_association" "start_rds_instances" {
  for_each = local.weekdays

  name                = "AWS-StartRdsInstance"
  association_name    = "${var.name_prefix}-start-rds-instances-${lower(each.key)}"
  schedule_expression = "cron(${var.start_rds_minute} ${var.start_rds_hour} ? * ${each.key} *)"

  parameters = {
    InstanceId           = ""
    AutomationAssumeRole = var.automation_role_arn
  }

  targets {
    key    = "tag-key"
    values = [var.schedule_tag_key]
  }

  automation_target_parameter_name = "InstanceId"
}

resource "aws_ssm_association" "stop_rds_instances" {
  for_each = local.weekdays

  name                = "AWS-StopRdsInstance"
  association_name    = "${var.name_prefix}-stop-rds-instances-${lower(each.key)}"
  schedule_expression = "cron(${var.stop_rds_minute} ${var.stop_rds_hour} ? * ${each.key} *)"

  parameters = {
    InstanceId           = ""
    AutomationAssumeRole = var.automation_role_arn
  }

  targets {
    key    = "tag-key"
    values = [var.schedule_tag_key]
  }

  automation_target_parameter_name = "InstanceId"
}

# ------------------------------------------------------------------------------
# SSM Associations — Aurora Clusters (Custom Document)
# One association per weekday.
# ------------------------------------------------------------------------------

resource "aws_ssm_association" "start_aurora_clusters" {
  for_each = local.weekdays

  name                             = aws_ssm_document.aurora_cluster_scheduler.name
  association_name                 = "${var.name_prefix}-start-aurora-clusters-${lower(each.key)}"
  schedule_expression              = "cron(${var.start_aurora_minute} ${var.start_aurora_hour} ? * ${each.key} *)"
  automation_target_parameter_name = "TargetKey"

  parameters = {
    AutomationAssumeRole = var.automation_role_arn
    Action               = "Start"
    ScheduleTagKey       = var.schedule_tag_key
  }
  # "ParameterValues" passes a literal value rather than performing a resource lookup, so SSM runs the automation once (not once-per-resource). The script ignores TargetKey
  targets {
    key    = "ParameterValues"
    values = ["placeholder"]
  }
}

resource "aws_ssm_association" "stop_aurora_clusters" {
  for_each = local.weekdays

  name                             = aws_ssm_document.aurora_cluster_scheduler.name
  association_name                 = "${var.name_prefix}-stop-aurora-clusters-${lower(each.key)}"
  schedule_expression              = "cron(${var.stop_aurora_minute} ${var.stop_aurora_hour} ? * ${each.key} *)"
  automation_target_parameter_name = "TargetKey"

  parameters = {
    AutomationAssumeRole = var.automation_role_arn
    Action               = "Stop"
    ScheduleTagKey       = var.schedule_tag_key
  }
  # "ParameterValues" passes a literal value rather than performing a resource lookup, so SSM runs the automation once (not once-per-resource). The script ignores TargetKey
  targets {
    key    = "ParameterValues"
    values = ["placeholder"]
  }
}


# ------------------------------------------------------------------------------
# SSM Automation Document — Aurora Cluster Discovery + Stop/Start
# ------------------------------------------------------------------------------

resource "aws_ssm_document" "aurora_cluster_scheduler" {
  name            = "${var.name_prefix}-aurora-cluster-scheduler"
  document_type   = "Automation"
  document_format = "JSON"
  tags            = var.tags

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Discover Aurora clusters by tag and perform Start/Stop actions."
    assumeRole    = "{{AutomationAssumeRole}}"

    parameters = {
      AutomationAssumeRole = {
        type           = "String"
        description    = "The ARN of the role that allows Automation to perform the actions on your behalf."
        default        = ""
        allowedPattern = "^arn:aws[a-z0-9-]*:iam::\\d{12}:role/[\\w+=,.@_/-]+|^$"
      }
      Action = {
        type          = "String"
        description   = "The action to take: Start or Stop."
        allowedValues = ["Start", "Stop"]
      }
      ScheduleTagKey = {
        type        = "String"
        description = "The tag key used to identify opt-in clusters."
        default     = "Schedule"
      }
      TargetKey = {
        type        = "StringList"
        description = "Reserved — not used by the script. Required by the SSM UpdateAssociation API when automation_target_parameter_name is set."
        default     = ["placeholder"]
      }
    }

    mainSteps = [
      {
        name   = "discoverAndManageClusters"
        action = "aws:executeScript"
        inputs = {
          Runtime = "python3.11"
          Handler = "handler"
          Script  = file("${path.module}/scripts/aurora_cluster_scheduler.py")
          InputPayload = {
            Action         = "{{Action}}"
            ScheduleTagKey = "{{ScheduleTagKey}}"
          }
        }
        outputs = [
          {
            Name     = "ProcessedClusters"
            Selector = "$.Payload.ProcessedClusters"
            Type     = "StringList"
          },
          {
            Name     = "SkippedClusters"
            Selector = "$.Payload.SkippedClusters"
            Type     = "StringList"
          },
          {
            Name     = "FailedClusters"
            Selector = "$.Payload.FailedClusters"
            Type     = "StringList"
          }
        ]
      }
    ]
  })
}