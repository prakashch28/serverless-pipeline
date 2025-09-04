variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
#variable "provider" {
# type    = string
#default = "aws"
#}

variable "alarm_email" {
  description = "Email for SNS alarms (optional)"
  type        = string
  default     = null
}

variable "raw_prefix" {
  type    = string
  default = "raw/"
}
variable "processed_prefix" {
  type    = string
  default = "processed/"
}

# Orchestrator schedule (EventBridge). Use a rate or cron. Example: rate(5 minutes)
variable "orchestrator_schedule" {
  type    = string
  default = "rate(30 minutes)"
}

# variables.tf
variable "project" {
  description = "Serverless pipeline project"
  type        = string
  default     = "log-pipeline"
}

variable "files_per_run" {
  type    = number
  default = 100
} # shards
variable "sample_n" {
  type    = number
  default = 50000
} # records per file
variable "record_bytes" {
  type    = number
  default = 1000
} # padding per record
variable "map_max_concurrency" {
  type    = number
  default = 20
} # parallelism
