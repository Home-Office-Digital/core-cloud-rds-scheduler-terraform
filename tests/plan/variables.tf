variable "name_prefix" {
  type = string
}

variable "automation_role_arn" {
  type = string
}

variable "schedule_tag_key" {
  type    = string
  default = "Schedule"
}

variable "tags" {
  type    = map(string)
  default = {}
}
