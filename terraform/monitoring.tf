# Lambda log group + alarm on Errors
resource "aws_cloudwatch_log_group" "lambda_lg" {
  name              = "/aws/lambda/${aws_lambda_function.ingest.function_name}"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.ingest.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "Lambda is throwing errors."
  alarm_actions       = var.alarm_email == null ? [] : [aws_sns_topic.alarms[0].arn]
  ok_actions          = var.alarm_email == null ? [] : [aws_sns_topic.alarms[0].arn]
  tags                = local.tags
}

# Glue log groups + metric filter for "ERROR" + alarm
#resource "aws_cloudwatch_log_group" "glue_output" {
#   name              = "/aws-glue/jobs/output"
#   retention_in_days = 14
#   tags              = local.tags
# }

# resource "aws_cloudwatch_log_group" "glue_error" {
#   name              = "/aws-glue/jobs/error"
#   retention_in_days = 14
#   tags              = local.tags
# }

resource "aws_cloudwatch_log_metric_filter" "glue_error_metric" {
  name           = "${local.name}-glue-error-filter"
  log_group_name = "/aws-glue/jobs/error"
  pattern        = "?ERROR ?Exception ?Traceback"

  metric_transformation {
    name      = "${local.name}-glue-errors"
    namespace = "${local.name}/glue"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "glue_errors" {
  alarm_name          = "${local.name}-glue-errors"
  namespace           = "Custom/Glue"
  metric_name         = "GlueJobErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "Glue job logged ERROR."
  alarm_actions       = var.alarm_email == null ? [] : [aws_sns_topic.alarms[0].arn]
  ok_actions          = var.alarm_email == null ? [] : [aws_sns_topic.alarms[0].arn]
  depends_on          = [aws_cloudwatch_log_metric_filter.glue_error_metric]
  tags                = local.tags
}

# Optional SNS for alarms
resource "aws_sns_topic" "alarms" {
  count = var.alarm_email == null ? 0 : 1
  name  = "${local.name}-alarms"
  tags  = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == null ? 0 : 1
  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}