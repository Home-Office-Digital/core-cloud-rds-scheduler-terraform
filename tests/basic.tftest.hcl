# This tells Terraform: "Don't connect to real AWS. Fake it."
# Without this, you'd need AWS credentials to run the tests.
mock_provider "aws" {}

# provider "aws" {
#   region = "eu-west-2"
# }
# run "default_schedules_are_weekday_only" {
#   command = apply

#   assert {
#     condition     = aws_ssm_association.start_aurora_clusters["MON"].schedule_expression == "cron(0 8 ? * MON *)"
#     error_message = "Default Aurora start on MON should be cron(0 8 ? * MON *)"
#   }
# }



# These variables apply to ALL run blocks in this file (unless overridden).
# They're the minimum required inputs for our module.
variables {
  name_prefix         = "cc-test-scheduler"
  automation_role_arn = "arn:aws:iam::123456789012:role/test-role"
}

# TEST 1: Basic plan succeeds

run "plan_succeeds_with_defaults" {
  command = plan

  assert {
    condition     = aws_ssm_document.aurora_cluster_scheduler.name == "cc-test-scheduler-aurora-cluster-scheduler"
    error_message = "SSM document should be created with the correct name"
  }
}

# TEST 2: All resource names use the name_prefix

run "resource_names_use_prefix" {
  command = plan

  assert {
    condition     = aws_ssm_association.start_rds_instances["MON"].association_name == "cc-test-scheduler-start-rds-instances-mon"
    error_message = "Start RDS instances MON should use name_prefix"
  }

  assert {
    condition     = aws_ssm_association.stop_rds_instances["MON"].association_name == "cc-test-scheduler-stop-rds-instances-mon"
    error_message = "Stop RDS instances MON should use name_prefix"
  }

  assert {
    condition     = aws_ssm_association.start_aurora_clusters["MON"].association_name == "cc-test-scheduler-start-aurora-clusters-mon"
    error_message = "Start Aurora clusters MON should use name_prefix"
  }

  assert {
    condition     = aws_ssm_association.stop_aurora_clusters["MON"].association_name == "cc-test-scheduler-stop-aurora-clusters-mon"
    error_message = "Stop Aurora clusters MON should use name_prefix"
  }

  assert {
    condition     = aws_ssm_document.aurora_cluster_scheduler.name == "cc-test-scheduler-aurora-cluster-scheduler"
    error_message = "SSM document name should use name_prefix"
  }
}



# TEST 3: Creates one association per weekday (5 each)


run "creates_association_per_weekday" {
  command = plan

  assert {
    condition     = length(aws_ssm_association.start_rds_instances) == 5
    error_message = "Should create 5 start RDS instance associations (one per weekday)"
  }

  assert {
    condition     = length(aws_ssm_association.stop_rds_instances) == 5
    error_message = "Should create 5 stop RDS instance associations (one per weekday)"
  }

  assert {
    condition     = length(aws_ssm_association.start_aurora_clusters) == 5
    error_message = "Should create 5 start Aurora associations (one per weekday)"
  }

  assert {
    condition     = length(aws_ssm_association.stop_aurora_clusters) == 5
    error_message = "Should create 5 stop Aurora associations (one per weekday)"
  }
}

# TEST 4: Default schedules are weekday-only

run "default_schedules_are_weekday_only" {
  command = plan

  # Assert start cron for every weekday (MON-FRI)
  assert {
    condition     = aws_ssm_association.start_rds_instances["MON"].schedule_expression == "cron(0 8 ? * MON *)"
    error_message = "Default instance start on MON should be cron(0 8 ? * MON *)"
  }
  assert {
    condition     = aws_ssm_association.start_rds_instances["TUE"].schedule_expression == "cron(0 8 ? * TUE *)"
    error_message = "Default instance start on TUE should be cron(0 8 ? * TUE *)"
  }
  assert {
    condition     = aws_ssm_association.start_rds_instances["WED"].schedule_expression == "cron(0 8 ? * WED *)"
    error_message = "Default instance start on WED should be cron(0 8 ? * WED *)"
  }
  assert {
    condition     = aws_ssm_association.start_rds_instances["THU"].schedule_expression == "cron(0 8 ? * THU *)"
    error_message = "Default instance start on THU should be cron(0 8 ? * THU *)"
  }
  assert {
    condition     = aws_ssm_association.start_rds_instances["FRI"].schedule_expression == "cron(0 8 ? * FRI *)"
    error_message = "Default instance start on FRI should be cron(0 8 ? * FRI *)"
  }

  # Assert stop cron for every weekday (MON-FRI)
  assert {
    condition     = aws_ssm_association.stop_rds_instances["MON"].schedule_expression == "cron(0 18 ? * MON *)"
    error_message = "Default instance stop on MON should be cron(0 18 ? * MON *)"
  }
  assert {
    condition     = aws_ssm_association.stop_rds_instances["TUE"].schedule_expression == "cron(0 18 ? * TUE *)"
    error_message = "Default instance stop on TUE should be cron(0 18 ? * TUE *)"
  }
  assert {
    condition     = aws_ssm_association.stop_rds_instances["WED"].schedule_expression == "cron(0 18 ? * WED *)"
    error_message = "Default instance stop on WED should be cron(0 18 ? * WED *)"
  }
  assert {
    condition     = aws_ssm_association.stop_rds_instances["THU"].schedule_expression == "cron(0 18 ? * THU *)"
    error_message = "Default instance stop on THU should be cron(0 18 ? * THU *)"
  }
  assert {
    condition     = aws_ssm_association.stop_rds_instances["FRI"].schedule_expression == "cron(0 18 ? * FRI *)"
    error_message = "Default instance stop on FRI should be cron(0 18 ? * FRI *)"
  }

  # Assert Aurora cluster start/stop cron for every weekday (MON-FRI)
  assert {
    condition     = aws_ssm_association.start_aurora_clusters["MON"].schedule_expression == "cron(0 8 ? * MON *)"
    error_message = "Default Aurora start on MON should be cron(0 8 ? * MON *)"
  }
  assert {
    condition     = aws_ssm_association.start_aurora_clusters["TUE"].schedule_expression == "cron(0 8 ? * TUE *)"
    error_message = "Default Aurora start on TUE should be cron(0 8 ? * TUE *)"
  }
  assert {
    condition     = aws_ssm_association.start_aurora_clusters["WED"].schedule_expression == "cron(0 8 ? * WED *)"
    error_message = "Default Aurora start on WED should be cron(0 8 ? * WED *)"
  }
  assert {
    condition     = aws_ssm_association.start_aurora_clusters["THU"].schedule_expression == "cron(0 8 ? * THU *)"
    error_message = "Default Aurora start on THU should be cron(0 8 ? * THU *)"
  }
  assert {
    condition     = aws_ssm_association.start_aurora_clusters["FRI"].schedule_expression == "cron(0 8 ? * FRI *)"
    error_message = "Default Aurora start on FRI should be cron(0 8 ? * FRI *)"
  }

  assert {
    condition     = aws_ssm_association.stop_aurora_clusters["MON"].schedule_expression == "cron(0 18 ? * MON *)"
    error_message = "Default Aurora stop on MON should be cron(0 18 ? * MON *)"
  }
  assert {
    condition     = aws_ssm_association.stop_aurora_clusters["TUE"].schedule_expression == "cron(0 18 ? * TUE *)"
    error_message = "Default Aurora stop on TUE should be cron(0 18 ? * TUE *)"
  }
  assert {
    condition     = aws_ssm_association.stop_aurora_clusters["WED"].schedule_expression == "cron(0 18 ? * WED *)"
    error_message = "Default Aurora stop on WED should be cron(0 18 ? * WED *)"
  }
  assert {
    condition     = aws_ssm_association.stop_aurora_clusters["THU"].schedule_expression == "cron(0 18 ? * THU *)"
    error_message = "Default Aurora stop on THU should be cron(0 18 ? * THU *)"
  }
  assert {
    condition     = aws_ssm_association.stop_aurora_clusters["FRI"].schedule_expression == "cron(0 18 ? * FRI *)"
    error_message = "Default Aurora stop on FRI should be cron(0 18 ? * FRI *)"
  }
}

# TEST 5: RDS instance associations target by Schedule tag .. This is how SSM finds which instances to stop/start. The targets

run "instance_associations_target_by_tag" {
  command = plan

  assert {
    condition     = aws_ssm_association.start_rds_instances["MON"].targets[0].key == "tag-key"
    error_message = "Start instances should target by 'tag-key'"
  }

  assert {
    condition     = contains(aws_ssm_association.start_rds_instances["MON"].targets[0].values, "Schedule")
    error_message = "Start instances should look for the 'Schedule' tag"
  }

  assert {
    condition     = aws_ssm_association.stop_rds_instances["MON"].targets[0].key == "tag-key"
    error_message = "Stop instances should target by 'tag-key'"
  }

  assert {
    condition     = contains(aws_ssm_association.stop_rds_instances["MON"].targets[0].values, "Schedule")
    error_message = "Stop instances should look for the 'Schedule' tag"
  }
}



# TEST 6: IAM role ARN is passed to all 4 associations.Every association needs the IAM role so SSM can assume it.

run "role_arn_passed_to_all_associations" {
  command = plan

  assert {
    condition     = aws_ssm_association.start_rds_instances["MON"].parameters["AutomationAssumeRole"] == "arn:aws:iam::123456789012:role/test-role"
    error_message = "Start RDS instances must have the role ARN"
  }

  assert {
    condition     = aws_ssm_association.stop_rds_instances["MON"].parameters["AutomationAssumeRole"] == "arn:aws:iam::123456789012:role/test-role"
    error_message = "Stop RDS instances must have the role ARN"
  }

  assert {
    condition     = aws_ssm_association.start_aurora_clusters["MON"].parameters["AutomationAssumeRole"] == "arn:aws:iam::123456789012:role/test-role"
    error_message = "Start Aurora clusters must have the role ARN"
  }

  assert {
    condition     = aws_ssm_association.stop_aurora_clusters["MON"].parameters["AutomationAssumeRole"] == "arn:aws:iam::123456789012:role/test-role"
    error_message = "Stop Aurora clusters must have the role ARN"
  }
}


# TEST 7: Empty tags map is valid

run "empty_tags_are_valid" {
  command = plan

  variables {
    tags = {}
  }

  assert {
    condition     = aws_ssm_document.aurora_cluster_scheduler.name == "cc-test-scheduler-aurora-cluster-scheduler"
    error_message = "Module should work fine with empty tags"
  }
}


# TEST 8: Module outputs return expected values. Consumers of this module depend on these outputs 
run "outputs_are_populated" {
  command = plan

  assert {
    condition     = output.ssm_document_name == "cc-test-scheduler-aurora-cluster-scheduler"
    error_message = "ssm_document_name output should match document name"
  }
}


# TEST 9: Additional association/document checks (ParameterValues, automation_target_parameter_name, document content)
run "association_and_document_checks" {
  command = plan

  # Aurora associations use the ParameterValues "one-shot" hack so the
  # automation script discovers clusters itself.
  assert {
    condition     = aws_ssm_association.start_aurora_clusters["MON"].targets[0].key == "ParameterValues"
    error_message = "Aurora start association should target via ParameterValues"
  }

  assert {
    condition     = contains(aws_ssm_association.start_aurora_clusters["MON"].targets[0].values, "placeholder")
    error_message = "Aurora start association should include a placeholder ParameterValues entry"
  }

  assert {
    condition     = aws_ssm_association.stop_aurora_clusters["MON"].targets[0].key == "ParameterValues"
    error_message = "Aurora stop association should target via ParameterValues"
  }

  assert {
    condition     = contains(aws_ssm_association.stop_aurora_clusters["MON"].targets[0].values, "placeholder")
    error_message = "Aurora stop association should include a placeholder ParameterValues entry"
  }

  # automation_target_parameter_name must be set correctly
  assert {
    condition     = aws_ssm_association.start_aurora_clusters["MON"].automation_target_parameter_name == "TargetKey"
    error_message = "Aurora associations should set automation_target_parameter_name to TargetKey"
  }

  assert {
    condition     = aws_ssm_association.start_rds_instances["MON"].automation_target_parameter_name == "InstanceId"
    error_message = "RDS instance associations should set automation_target_parameter_name to InstanceId"
  }

  # The automation document content should expose the expected outputs and
  # include the embedded script text (we check for a known function signature).
  assert {
    condition     = length(regexall("ProcessedClusters", aws_ssm_document.aurora_cluster_scheduler.content)) > 0
    error_message = "Automation document should include ProcessedClusters output"
  }

  assert {
    condition     = length(regexall("def handler", aws_ssm_document.aurora_cluster_scheduler.content)) > 0
    error_message = "Automation document should include the embedded script (handler function)"
  }
}