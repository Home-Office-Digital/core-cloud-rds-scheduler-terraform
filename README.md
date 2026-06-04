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

### Terraform tests: plan vs apply

This repo has two Terraform test suites:

- **Plan tests** in `tests/plan/rds_scheduler_plan.tftest.hcl`
  - Use `mock_provider "aws" {}` so they **do not** require AWS credentials.
  - Validate naming, schedules, association counts, and outputs from a `terraform plan`.

- **Apply tests** in `tests/apply/rds_scheduler_apply.tftest.hcl`
  - Use the real AWS provider and `command = apply`, so they **create real AWS resources**.
  - Require AWS credentials and a configured AWS region.
  - Intended for CI environments with an isolated test account.

Run all Terraform tests:

```bash
terraform test
```

Run only plan tests (recommended locally):

```bash
terraform test -verbose -test-directory=tests/plan
```

Run only apply tests (requires AWS credentials/region):

```bash
terraform test -verbose -test-directory=tests/apply
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

### Terratest (integration)

There is an integration test in `tests/terratest` that provisions real AWS resources and validates runtime behavior by manually triggering SSM automation/association executions.

To keep the **production module** unchanged (associations always created) while avoiding provisioning-time race conditions in restricted org environments, the test uses **two separate Terraform roots**:

- `tests/terratest/fixtures-db`: creates disposable **RDS + Aurora** resources (tagged to opt-in)
- `tests/terratest/fixtures-scheduler`: applies the **scheduler module** (SSM document + associations)

This ensures the databases exist before any SSM scheduling is created.

#### Prerequisites

- **AWS credentials** able to create and destroy RDS, SSM, IAM (for pass/assume role), and basic EC2 networking resources.
- **AWS region** set (via `AWS_REGION`/`AWS_DEFAULT_REGION`).
- Terraform installed.
- Go installed.

The test expects an **Automation assume role** to exist and be assumable by SSM. By default this is the role passed into the module (see [IAM Role Requirements](#iam-role-requirements)).

#### What it does (runtime contract)

The test:

1. Applies `fixtures-db` to create an RDS instance and an Aurora cluster, tagged to opt in (`Schedule=true`).
2. Applies `fixtures-scheduler` to create the SSM Automation document + State Manager associations.
3. Manually triggers:
  - the Aurora Automation document twice (idempotency)
  - a single SSM association run twice (idempotency)
4. Destroys scheduler resources first, then DB resources.

It also performs a best-effort pre-test cleanup of any leftover `test-rds-scheduler-*` resources.

#### Running locally

From `tests/terratest`:

```bash
go test -run TestRDSScheduler_RuntimeExecutions -count=1 -timeout 80m
```

If you want verbose logs:

```bash
go test -run TestRDSScheduler_RuntimeExecutions -count=1 -timeout 80m -v
```

#### Safety / cost notes

- This test creates real RDS resources (including an Aurora writer instance). Expect it to take ~20–30 minutes.
- Resource names are prefixed with `test-rds-scheduler-`.
- Opt-in is tag based; only resources with the `Schedule` tag should ever be targeted by the module role conditions.



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