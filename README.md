# RDS Scheduled Stop/Start

Terraform module that automatically stops and starts RDS instances and Aurora clusters on a schedule using AWS Systems Manager (SSM) State Manager. Resources opt-in by adding a `Schedule` tag.

## Usage
```hcl
module "rds_scheduled_stop_start" {
  source = "git::https://github.com/Home-Office-Digital/core-cloud-rds-scheduled-terraform.git?ref=v1.0.0"

  name_prefix        = "cc-rds-scheduler"
  automation_role_arn = aws_iam_role.ssm_rds_scheduler.arn
  schedule_tag_key   = "Schedule"

  # Defaults: all RDS up 8am-6pm UTC weekdays
  # start_rds_hour       = 8   (default)
  # stop_rds_hour        = 18  (default)
  # start_aurora_hour    = 8   (default)
  # stop_aurora_hour     = 18  (default)

  tags = {
    cost-centre  = "1709144"
    account-code = "521835"
    portfolio-id = "CTO"
    project-id   = "CC"
    service-id   = "rds-scheduled-stop-start"
  }
}
```

**Note:** This module does NOT create the IAM role. The calling code must create it with the correct tag-based condition. See [IAM Role Requirements](#iam-role-requirements) below.

## Architecture

```
SSM State Manager (20 associations: 4 actions x 5 weekdays)
├── RDS Instances (AWS managed documents)
│   ├── AWS-StartRdsInstance  →  targets by tag-key "Schedule"  (MON-FRI)
│   └── AWS-StopRdsInstance   →  targets by tag-key "Schedule"  (MON-FRI)
│
└── Aurora Clusters (custom automation document)
    └── cc-rds-scheduler-aurora-cluster-scheduler
        ├── Discovers clusters via DescribeDBClusters API
        ├── Filters by "Schedule" tag
        ├── Filters out unstoppable types (serverless, global, etc.)
        └── Calls StartDBCluster / StopDBCluster
```

### Why 20 associations?

SSM State Manager associations only support single day-of-week values (e.g. `MON`), not ranges (e.g. `MON-FRI`). Ranges are only supported for maintenance windows. The module uses `for_each` to create one association per weekday for each action (start/stop x instances/clusters = 4 actions x 5 days = 20).

### SSM Cron Format

SSM associations use **6-field cron** (seconds field is optional):

```
cron(minutes hours day_of_month month day_of_week year)
```

Example: `cron(0 8 ? * MON *)` = every Monday at 08:00 UTC.

### Schedule staggering

| Time (UTC) | Action | Days |
|---|---|---|
| 08:00 | Start RDS instances + Aurora clusters | MON-FRI |
| 18:00 | Stop RDS instances + Aurora clusters | MON-FRI |

All RDS databases are available 8am–6pm UTC weekdays. Nothing runs on weekends.

## Opting in a database

Add a `Schedule` tag to any RDS instance or Aurora cluster:

```
Tag Key:   Schedule
Tag Value: <any value, e.g. "weekdays" or "true">
```

The IAM policy restricts stop/start to resources with this tag — untagged resources cannot be affected.

## Inputs

| Name | Description | Default |
|---|---|---|
| `name_prefix` | Prefix for all resource names | — (required) |
| `automation_role_arn` | IAM role ARN for SSM to assume | — (required) |
| `schedule_tag_key` | Tag key for opt-in | `Schedule` |
| `start_rds_hour` | UTC hour to start instances | `8` |
| `start_rds_minute` | UTC minute to start instances | `0` |
| `stop_rds_hour` | UTC hour to stop instances | `18` |
| `stop_rds_minute` | UTC minute to stop instances | `0` |
| `start_aurora_hour` | UTC hour to start clusters | `8` |
| `start_aurora_minute` | UTC minute to start clusters | `0` |
| `stop_aurora_hour` | UTC hour to stop clusters | `18` |
| `stop_aurora_minute` | UTC minute to stop clusters | `0` |
| `tags` | Tags for module-created resources | `{}` |

## Testing

```bash
terraform init
terraform test            # run all tests
terraform test -verbose   # show each assertion
```

### Python tests (pytest)

This repository now includes a pytest suite that validates the custom Aurora Cluster scheduler (`scripts/aurora_cluster_scheduler.py`). Tests mock AWS interactions and run locally and in CI.

Run the Python tests locally:

```bash
python -m pip install --upgrade pip
pip install pytest coverage
pytest -q
# or with coverage
coverage run -m pytest
coverage report -m
```

CI: A GitHub Actions workflow (`.github/workflows/pytest.yml`) runs the pytest suite on push/PR and uploads the test artifacts (pytest log) as a build artifact named `test-artifacts`. You can download these artifacts from the workflow run and attach the logs to your Jira ticket as evidence.



## IAM Role Requirements

The calling code must create an IAM role with:

1. **Trust policy:** Allow `ssm.amazonaws.com` to assume the role
2. **Permissions:**
   - `rds:StopDBCluster`, `rds:StartDBCluster`, `rds:StopDBInstance`, `rds:StartDBInstance` — restricted by tag condition `aws:ResourceTag/Schedule = *`
   - `rds:DescribeDBClusters`, `rds:DescribeDBInstances`, `rds:ListTagsForResource` — on all resources (required for discovery)

Example:
```hcl
resource "aws_iam_role" "ssm_rds_scheduler" {
  name = "cc-ssm-rds-scheduled-stop-start-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ssm_rds_scheduler" {
  name = "cc-ssm-rds-scheduled-stop-start-policy"
  role = aws_iam_role.ssm_rds_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowStopStartTaggedResourcesOnly"
        Effect   = "Allow"
        Action   = [
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
        Sid      = "AllowDescribeForDiscovery"
        Effect   = "Allow"
        Action   = [
          "rds:DescribeDBClusters",
          "rds:DescribeDBInstances",
          "rds:ListTagsForResource"
        ]
        Resource = "*"
      }
    ]
  })
}
```