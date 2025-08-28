# ---- Lambda role ----

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${local.name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_s3" {
  statement {
    actions   = ["s3:PutObject", "s3:PutObjectAcl"]
    resources = ["${aws_s3_bucket.raw.arn}/${var.raw_prefix}*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.raw.arn]
  }
}

resource "aws_iam_policy" "lambda_s3_policy" {
  name   = "${local.name}-lambda-s3"
  policy = data.aws_iam_policy_document.lambda_s3.json
}

resource "aws_iam_role_policy_attachment" "lambda_s3_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}

# ----- Glue role -----

data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_role" {
  name               = "${local.name}-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_s3" {
  statement {
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.raw.arn}/*",
      "${aws_s3_bucket.processed.arn}/*"
    ]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.raw.arn, aws_s3_bucket.processed.arn]
  }
}

resource "aws_iam_policy" "glue_s3_policy" {
  name   = "${local.name}-glue-s3"
  policy = data.aws_iam_policy_document.glue_s3.json
}

resource "aws_iam_role_policy_attachment" "glue_s3_attach" {
  role       = aws_iam_role.glue_role.name
  policy_arn = aws_iam_policy.glue_s3_policy.arn
}

resource "aws_iam_role_policy_attachment" "glue_logs" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

# ----- step functions role -----

# ---------- Step Functions: trust policy ----------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn_role" {
  name               = "${local.name}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags               = local.tags
}

# ---------- Step Functions: permissions ----------
# NOTE:
# - Statement 1 MUST use resources="*" for LogDelivery APIs (AWS requirement)
# - Statement 2 targets YOUR log group (both arn and arn:*)
# - Add both Lambda ARNs if you have a DQ lambda; if not, remove that line.

data "aws_iam_policy_document" "sfn_logs_and_actions" {
  # 1) Required for SFN logging integration
  statement {
    sid = "CWLogsDeliveryAPIs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups"
    ]
    resources = ["*"]
  }

  # 2) Allow writing to your specific SFN log group
  statement {
    sid = "CWLogsWriteToGroup"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy"
    ]
    resources = [
      aws_cloudwatch_log_group.sfn_lg.arn,
      "${aws_cloudwatch_log_group.sfn_lg.arn}:*"
    ]
  }

  # 3) Invoke Lambdas used by the state machine
  statement {
    sid     = "InvokeLambda"
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.ingest.arn,
      # uncomment next line only if you created the DQ lambda
      # aws_lambda_function.dq.arn
    ]
  }

  # 4) Run and poll Glue resources (kept wide for simplicity in class projects)
  statement {
    sid = "GlueRunAndRead"
    actions = [
      "glue:StartCrawler",
      "glue:GetCrawler",
      "glue:StartJobRun",
      "glue:GetJobRun"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "sfn_logs_and_actions" {
  name   = "${local.name}-sfn-logs-and-actions"
  policy = data.aws_iam_policy_document.sfn_logs_and_actions.json
}

resource "aws_iam_role_policy_attachment" "sfn_logs_and_actions_attach" {
  role       = aws_iam_role.sfn_role.name
  policy_arn = aws_iam_policy.sfn_logs_and_actions.arn
}


# ---------- EventBridge -> Step Functions permission ----------
data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_to_sfn" {
  name               = "${local.name}-events-to-sfn"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "events_to_sfn_policy_doc" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.pipeline.arn]
  }
}

resource "aws_iam_policy" "events_to_sfn_policy" {
  name   = "${local.name}-events-to-sfn-policy"
  policy = data.aws_iam_policy_document.events_to_sfn_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "events_to_sfn_attach" {
  role       = aws_iam_role.events_to_sfn.name
  policy_arn = aws_iam_policy.events_to_sfn_policy.arn
}