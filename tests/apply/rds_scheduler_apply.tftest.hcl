# Apply-level integration test (real AWS provider)
#
# - Validates resource creation/configuration only (not runtime execution)
# - Requires AWS credentials + region in CI
# - Does NOT depend on any real RDS/Aurora resources existing

run "apply_creates_expected_resources" {
  command = apply

  variables {
    # NOTE: Ideally this would be a true random suffix (e.g. random_string), but
    # terraform test doesn't provide a built-in RNG without adding providers to
    # the module itself. For local runs, set TF_VAR_name_prefix to a unique
    # value if you hit collisions.
    name_prefix         = "test-rds-scheduler"
  automation_role_arn = "arn:aws:iam::741448916464:role/cc-ssm-rds-scheduled-stop-start-role"
    schedule_tag_key    = "Schedule"

    # Use non-default values so schedule assertions are deterministic.
    start_rds_hour      = 9
    start_rds_minute    = 5
    stop_rds_hour       = 19
    stop_rds_minute     = 55
    start_aurora_hour   = 9
    start_aurora_minute = 15
    stop_aurora_hour    = 19
    stop_aurora_minute  = 45

    tags = {
      Test = "true"
    }
  }

  # ---------------------------------------------------------------------------
  # Resource creation: 5 associations per type.
  # ---------------------------------------------------------------------------

  assert {
    condition     = length(aws_ssm_association.start_rds_instances) == 5
    error_message = "Expected 5 start RDS instance associations (MON-FRI)"
  }

  assert {
    condition     = length(aws_ssm_association.stop_rds_instances) == 5
    error_message = "Expected 5 stop RDS instance associations (MON-FRI)"
  }

  assert {
    condition     = length(aws_ssm_association.start_aurora_clusters) == 5
    error_message = "Expected 5 start Aurora cluster associations (MON-FRI)"
  }

  assert {
    condition     = length(aws_ssm_association.stop_aurora_clusters) == 5
    error_message = "Expected 5 stop Aurora cluster associations (MON-FRI)"
  }

  # Weekday keys exist in all four association maps.
  assert {
    condition = alltrue([
  for d in ["MON", "TUE", "WED", "THU", "FRI"] : contains(keys(aws_ssm_association.start_rds_instances), d)
    ])
    error_message = "start_rds_instances must include keys MON-FRI"
  }

  assert {
    condition = alltrue([
  for d in ["MON", "TUE", "WED", "THU", "FRI"] : contains(keys(aws_ssm_association.stop_rds_instances), d)
    ])
    error_message = "stop_rds_instances must include keys MON-FRI"
  }

  assert {
    condition = alltrue([
  for d in ["MON", "TUE", "WED", "THU", "FRI"] : contains(keys(aws_ssm_association.start_aurora_clusters), d)
    ])
    error_message = "start_aurora_clusters must include keys MON-FRI"
  }

  assert {
    condition = alltrue([
  for d in ["MON", "TUE", "WED", "THU", "FRI"] : contains(keys(aws_ssm_association.stop_aurora_clusters), d)
    ])
    error_message = "stop_aurora_clusters must include keys MON-FRI"
  }

  # ---------------------------------------------------------------------------
  # Schedules: cron(<minute> <hour> ? * <DAY> *) for each weekday.
  # ---------------------------------------------------------------------------

  assert {
    condition = alltrue([
  for d in ["MON", "TUE", "WED", "THU", "FRI"] : aws_ssm_association.start_rds_instances[d].schedule_expression == "cron(5 9 ? * ${d} *)"
    ])
    error_message = "Start RDS schedule_expression must match cron(5 9 ? * <DAY> *)"
  }

  assert {
    condition = alltrue([
  for d in ["MON", "TUE", "WED", "THU", "FRI"] : aws_ssm_association.stop_rds_instances[d].schedule_expression == "cron(55 19 ? * ${d} *)"
    ])
    error_message = "Stop RDS schedule_expression must match cron(55 19 ? * <DAY> *)"
  }

  assert {
    condition = alltrue([
  for d in ["MON", "TUE", "WED", "THU", "FRI"] : aws_ssm_association.start_aurora_clusters[d].schedule_expression == "cron(15 9 ? * ${d} *)"
    ])
    error_message = "Start Aurora schedule_expression must match cron(15 9 ? * <DAY> *)"
  }

  assert {
    condition = alltrue([
  for d in ["MON", "TUE", "WED", "THU", "FRI"] : aws_ssm_association.stop_aurora_clusters[d].schedule_expression == "cron(45 19 ? * ${d} *)"
    ])
    error_message = "Stop Aurora schedule_expression must match cron(45 19 ? * <DAY> *)"
  }

  # General pattern validation (defensive)
  assert {
  condition     = length(regexall("^cron\\(\\d{1,2}\\s+\\d{1,2}\\s+\\?\\s+\\*\\s+(MON|TUE|WED|THU|FRI)\\s+\\*\\)$", aws_ssm_association.start_rds_instances["MON"].schedule_expression)) == 1
    error_message = "schedule_expression should match cron(<minute> <hour> ? * <DAY> *)"
  }

  # ---------------------------------------------------------------------------
  # SSM association config.
  # ---------------------------------------------------------------------------

  # RDS associations use AWS managed docs
  assert {
  condition     = aws_ssm_association.start_rds_instances["MON"].name == "AWS-StartRdsInstance"
    error_message = "RDS start associations must use AWS-StartRdsInstance"
  }

  assert {
  condition     = aws_ssm_association.stop_rds_instances["MON"].name == "AWS-StopRdsInstance"
    error_message = "RDS stop associations must use AWS-StopRdsInstance"
  }

  # Aurora associations reference custom doc
  assert {
  condition     = aws_ssm_association.start_aurora_clusters["MON"].name == aws_ssm_document.aurora_cluster_scheduler.name
    error_message = "Aurora start associations must reference the custom SSM document"
  }

  assert {
  condition     = aws_ssm_association.stop_aurora_clusters["MON"].name == aws_ssm_document.aurora_cluster_scheduler.name
    error_message = "Aurora stop associations must reference the custom SSM document"
  }

  # automation_target_parameter_name
  assert {
  condition     = aws_ssm_association.start_rds_instances["MON"].automation_target_parameter_name == "InstanceId"
    error_message = "RDS associations must set automation_target_parameter_name to InstanceId"
  }

  assert {
  condition     = aws_ssm_association.start_aurora_clusters["MON"].automation_target_parameter_name == "TargetKey"
    error_message = "Aurora associations must set automation_target_parameter_name to TargetKey"
  }

  # required parameters exist
  assert {
    condition = alltrue([
      for d in ["MON", "TUE", "WED", "THU", "FRI"] : (
  try(aws_ssm_association.start_rds_instances[d].parameters["AutomationAssumeRole"], "") != "" &&
  try(aws_ssm_association.stop_rds_instances[d].parameters["AutomationAssumeRole"], "") != ""
      )
    ])
    error_message = "All RDS associations must include AutomationAssumeRole"
  }

  assert {
    condition = (
  aws_ssm_association.start_aurora_clusters["MON"].parameters["AutomationAssumeRole"] != "" &&
  aws_ssm_association.start_aurora_clusters["MON"].parameters["Action"] == "Start" &&
  aws_ssm_association.start_aurora_clusters["MON"].parameters["ScheduleTagKey"] == "Schedule"
    )
    error_message = "Aurora start association must include AutomationAssumeRole/Action/ScheduleTagKey"
  }

  assert {
    condition = (
  aws_ssm_association.stop_aurora_clusters["MON"].parameters["AutomationAssumeRole"] != "" &&
  aws_ssm_association.stop_aurora_clusters["MON"].parameters["Action"] == "Stop" &&
  aws_ssm_association.stop_aurora_clusters["MON"].parameters["ScheduleTagKey"] == "Schedule"
    )
    error_message = "Aurora stop association must include AutomationAssumeRole/Action/ScheduleTagKey"
  }

  # targeting config
  assert {
  condition     = aws_ssm_association.start_rds_instances["MON"].targets[0].key == "tag-key"
    error_message = "RDS associations must target by tag-key"
  }

  assert {
  condition     = contains(aws_ssm_association.start_rds_instances["MON"].targets[0].values, "Schedule")
    error_message = "RDS associations must include schedule tag key in targets"
  }

  assert {
  condition     = aws_ssm_association.start_aurora_clusters["MON"].targets[0].key == "ParameterValues"
    error_message = "Aurora associations must use ParameterValues target hack"
  }

  # ---------------------------------------------------------------------------
  # SSM document validation.
  # ---------------------------------------------------------------------------

  assert {
  condition     = aws_ssm_document.aurora_cluster_scheduler.name != ""
    error_message = "SSM document must exist"
  }

  assert {
  condition     = aws_ssm_document.aurora_cluster_scheduler.document_type == "Automation"
    error_message = "SSM document type must be Automation"
  }

  assert {
  condition     = length(regexall("\\\"Action\\\"", aws_ssm_document.aurora_cluster_scheduler.content)) > 0
    error_message = "SSM document content should contain an Action parameter"
  }

  assert {
  condition     = length(regexall("\\\"allowedValues\\\"\\s*:\\s*\\[\\s*\\\"Start\\\"\\s*,\\s*\\\"Stop\\\"\\s*\\]", aws_ssm_document.aurora_cluster_scheduler.content)) > 0
    error_message = "SSM document Action parameter must allow Start/Stop"
  }

  assert {
  condition     = length(regexall("\\\"ScheduleTagKey\\\"", aws_ssm_document.aurora_cluster_scheduler.content)) > 0
    error_message = "SSM document content should contain ScheduleTagKey parameter"
  }

  # ---------------------------------------------------------------------------
  # Outputs.
  # ---------------------------------------------------------------------------

  assert {
    condition     = output.ssm_document_name != ""
    error_message = "Output ssm_document_name should be populated"
  }

  assert {
    condition     = length(output.instance_start_association_ids) == 5
    error_message = "Output instance_start_association_ids must have 5 entries"
  }

  assert {
    condition     = length(output.instance_stop_association_ids) == 5
    error_message = "Output instance_stop_association_ids must have 5 entries"
  }

  assert {
    condition     = length(output.aurora_start_association_ids) == 5
    error_message = "Output aurora_start_association_ids must have 5 entries"
  }

  assert {
    condition     = length(output.aurora_stop_association_ids) == 5
    error_message = "Output aurora_stop_association_ids must have 5 entries"
  }

}

run "reapply_is_idempotent" {
  command = plan

  variables {
    name_prefix         = "test-rds-scheduler"
  automation_role_arn = "arn:aws:iam::741448916464:role/cc-ssm-rds-scheduled-stop-start-role"
    schedule_tag_key    = "Schedule"

    start_rds_hour      = 9
    start_rds_minute    = 5
    stop_rds_hour       = 19
    stop_rds_minute     = 55
    start_aurora_hour   = 9
    start_aurora_minute = 15
    stop_aurora_hour    = 19
    stop_aurora_minute  = 45

    tags = {
      Test = "true"
    }
  }

  # Terraform test doesn't expose a "resource_changes" plan summary in this
  # context, so we use a deterministic proxy: key resource attributes should
  # remain exactly the same after a re-plan.
  assert {
    condition     = aws_ssm_document.aurora_cluster_scheduler.name == output.ssm_document_name
    error_message = "Re-plan should keep the SSM document name stable"
  }

  assert {
    condition     = length(aws_ssm_association.start_rds_instances) == 5
    error_message = "Re-plan should still have 5 start RDS instance associations"
  }

  assert {
    condition     = aws_ssm_association.start_rds_instances["MON"].schedule_expression == "cron(5 9 ? * MON *)"
    error_message = "Re-plan should keep schedule expressions stable"
  }
}
