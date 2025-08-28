############################################
# Step Functions: fan-out Lambda -> Glue ETL (minute-scoped)
############################################

resource "aws_cloudwatch_log_group" "sfn_lg" {
  name              = "/aws/states/${local.name}-sfn"
  retention_in_days = 14
  tags              = local.tags
}

# Build the shards array used by the Map state
locals {
  shards = [for i in range(var.files_per_run) : {
    shard        = i
    sample_n     = var.sample_n
    record_bytes = var.record_bytes
  }]

  sfn_definition = jsonencode({
    Comment = "Fan-out Lambda writers -> compute RawDate -> Glue Job"
    StartAt = "GenerateShards"
    States = {
      GenerateShards = {
        Type           = "Map"
        ItemsPath      = "$.shards"
        MaxConcurrency = var.map_max_concurrency
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }
          StartAt         = "InvokeIngestLambda"
          States = {
            InvokeIngestLambda = {
              Type       = "Task"
              Resource   = "arn:aws:states:::lambda:invoke"
              OutputPath = "$.Payload"
              Parameters = {
                FunctionName = aws_lambda_function.ingest.arn
                Payload = {
                  "sample_n.$" : "$.sample_n"
                  "record_bytes.$" : "$.record_bytes"
                }
              }
              Retry = [
                {
                  ErrorEquals     = ["Lambda.TooManyRequestsException", "Lambda.ServiceException", "Lambda.AWSLambdaException"]
                  IntervalSeconds = 2
                  BackoffRate     = 2.0
                  MaxAttempts     = 6
                }
              ]
              End = true
            }
          }
        }
        ResultPath = "$.ShardResults"
        Next       = "SplitKey"
      },

      # 1) Split the first S3 key into parts and store at $.Window.Parts
      SplitKey = {
        Type       = "Pass"
        ResultPath = "$.Window"
        Parameters = {
          "Parts.$" : "States.StringSplit($.ShardResults[0].key, '/')"
        }
        Next = "BuildRawDate"
      },

      # 2) Build yyyy/mm/dd/HH/mm from the parts and store at $.Window.RawDate
      BuildRawDate = {
        Type       = "Pass"
        ResultPath = "$.Window"
        Parameters = {
          "RawDate.$" : "States.Format('{}/{}/{}/{}/{}', $.Window.Parts[1], $.Window.Parts[2], $.Window.Parts[3], $.Window.Parts[4], $.Window.Parts[5])"
        }
        Next = "StartGlueJob"
      },

      StartGlueJob = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startJobRun"
        Parameters = {
          JobName = aws_glue_job.etl.name
          Arguments = {
            "--RAW_DATE.$" : "$.Window.RawDate"
          }
        }
        ResultPath = "$.Job"
        Next       = "WaitForJob"
      },

      WaitForJob = { Type = "Wait", Seconds = 30, Next = "GetJobStatus" },

      GetJobStatus = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getJobRun"
        Parameters = {
          JobName              = aws_glue_job.etl.name
          "RunId.$"            = "$.Job.JobRunId"
          PredecessorsIncluded = false
        }
        ResultSelector = {
          "State.$" : "$.JobRun.JobRunState"
          "Id.$" : "$.JobRun.Id"
          "StartedOn.$" : "$.JobRun.StartedOn"
          "ExecutionTime.$" : "$.JobRun.ExecutionTime"
        }
        ResultPath = "$.Status"
        Next       = "JobComplete?"
      },

      "JobComplete?" = {
        Type = "Choice"
        Choices = [
          { Variable = "$.Status.State", StringEquals = "SUCCEEDED", Next = "Success" },
          { Variable = "$.Status.State", StringEquals = "FAILED", Next = "Fail" },
          { Variable = "$.Status.State", StringEquals = "STOPPED", Next = "Fail" }
        ]
        Default = "WaitForJob"
      },

      Success = { Type = "Succeed" },
      Fail    = { Type = "Fail" }
    }
  })
}

resource "aws_sfn_state_machine" "pipeline" {
  name       = "${local.name}-sfn"
  role_arn   = aws_iam_role.sfn_role.arn
  definition = local.sfn_definition

  logging_configuration {
    include_execution_data = true
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.sfn_lg.arn}:*"
  }

  tags = local.tags
}

resource "aws_cloudwatch_event_rule" "orchestrator" {
  name                = "${local.name}-orchestrator"
  schedule_expression = var.orchestrator_schedule
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "orchestrator_target" {
  rule      = aws_cloudwatch_event_rule.orchestrator.name
  target_id = "sfn"
  arn       = aws_sfn_state_machine.pipeline.arn
  role_arn  = aws_iam_role.events_to_sfn.arn
  input     = jsonencode({ shards = local.shards })
}
