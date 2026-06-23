// Module wrapper used by terraform test harness. This instantiates the
// module under test (repo root) using variables provided by the .tftest.hcl
// run blocks.
module "rds_scheduler" {
  source               = "../../"
  name_prefix          = var.name_prefix
  automation_role_arn  = var.automation_role_arn
  schedule_tag_key     = var.schedule_tag_key
  tags                 = var.tags

  # Other inputs can use module defaults; tests override where needed.
}
