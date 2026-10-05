# Phase 11 — one execution role per function, each holding only what that
# function's code calls. Function names are locals so the IAM policies can
# reference them without depending on the functions themselves (which depend
# on the policies — see depends_on below).
locals {
  api_function_name      = "${var.project_name}-${var.environment}-api"
  consumer_function_name = "${var.project_name}-${var.environment}-consumer"

  # Built by hand rather than from aws_cloudwatch_log_group.*.arn: those log
  # groups reference the functions, so using them here would be a cycle.
  # Must stay in step with the names in cloudwatch.tf.
  log_group_arn_prefix   = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda"
  api_log_group_arn      = "${local.log_group_arn_prefix}/${local.api_function_name}"
  consumer_log_group_arn = "${local.log_group_arn_prefix}/${local.consumer_function_name}"

  lambda_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# ---------------------------------------------------------------------------
# API Lambda role: presign uploads, register and list documents
# ---------------------------------------------------------------------------

resource "aws_iam_role" "api_lambda_role" {
  name               = "${var.project_name}-${var.environment}-api-lambda-role"
  assume_role_policy = local.lambda_assume_role_policy
}

resource "aws_iam_role_policy" "api_lambda_policy" {
  name = "${var.project_name}-${var.environment}-api-lambda-policy"
  role = aws_iam_role.api_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Replaces AWSLambdaBasicExecutionRole, which grants these on every
        # log group in the account. The group is Terraform-managed, so
        # CreateLogGroup only matters if someone deletes it out-of-band.
        Sid    = "WriteOwnLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          local.api_log_group_arn,
          "${local.api_log_group_arn}:*"
        ]
      },
      {
        # put_item registers the AWAITING_UPLOAD row; query lists documents.
        Sid    = "RegisterAndListDocuments"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:Query"
        ]
        Resource = aws_dynamodb_table.documents.arn
      },
      {
        # Needed to SIGN the presigned PUT. A presigned URL can never grant
        # more than the signer already holds, so this permission is what makes
        # the browser upload work — and what bounds it. Scoped to the uploads/
        # prefix so a bug in key construction cannot write elsewhere.
        Sid    = "SignPresignedUploads"
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.raw_documents.arn}/uploads/*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Consumer Lambda role: drain the queue, read the PDF, Textract, upsert status
# ---------------------------------------------------------------------------

resource "aws_iam_role" "consumer_lambda_role" {
  name               = "${var.project_name}-${var.environment}-consumer-lambda-role"
  assume_role_policy = local.lambda_assume_role_policy
}

resource "aws_iam_role_policy" "consumer_lambda_policy" {
  name = "${var.project_name}-${var.environment}-consumer-lambda-policy"
  role = aws_iam_role.consumer_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # See WriteOwnLogs on the API role.
        Sid    = "WriteOwnLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          local.consumer_log_group_arn,
          "${local.consumer_log_group_arn}:*"
        ]
      },
      {
        # Used by the SQS event source mapping's poller, which runs as the
        # function's execution role — not by the function code itself.
        Sid    = "PollProcessingQueue"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.document_processing_queue.arn
      },
      {
        # update_item only (_mark upserts); never put_item, so the API's
        # presign-time fields are not clobbered.
        Sid    = "UpdateDocumentStatus"
        Effect = "Allow"
        Action = [
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.documents.arn
      },
      {
        Sid    = "ReadRawDocuments"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.raw_documents.arn}/uploads/*"
      },
      {
        # Textract has no resource-level permissions — the actions only accept
        # "*". Scoping happens through what the function can read from S3,
        # which is the uploads/ prefix above.
        Sid    = "TextractExpenseAnalysis"
        Effect = "Allow"
        Action = [
          "textract:AnalyzeExpense"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "api_lambda" {
  function_name = local.api_function_name
  role          = aws_iam_role.api_lambda_role.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.12"

  filename         = "../../backend/api_lambda.zip"
  source_code_hash = filebase64sha256("../../backend/api_lambda.zip")

  # Presigning is cheap but the SDK import is not; give it room to stay warm.
  timeout     = 10
  memory_size = 256

  environment {
    variables = {
      RAW_BUCKET             = aws_s3_bucket.raw_documents.bucket
      TABLE_NAME             = aws_dynamodb_table.documents.name
      MAX_UPLOAD_BYTES       = tostring(var.max_upload_bytes)
      UPLOAD_URL_TTL_SECONDS = tostring(var.upload_url_ttl_seconds)
    }
  }

  # Attach permissions before switching the function onto the new role, so
  # there is no window where it runs with an empty role.
  depends_on = [aws_iam_role_policy.api_lambda_policy]
}

resource "aws_lambda_function" "consumer_lambda" {
  function_name = local.consumer_function_name
  role          = aws_iam_role.consumer_lambda_role.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.12"

  filename         = "../../backend/consumer_lambda.zip"
  source_code_hash = filebase64sha256("../../backend/consumer_lambda.zip")

  # Textract is a synchronous network call to another region, and the function
  # also downloads the PDF first. Must stay well under the queue's 300s
  # visibility timeout.
  timeout     = 45
  memory_size = 512

  environment {
    variables = {
      TABLE_NAME         = aws_dynamodb_table.documents.name
      TEXTRACT_REGION    = var.textract_region
      MAX_TEXTRACT_BYTES = tostring(var.max_upload_bytes)
    }
  }

  # As above. Matters more here: the SQS poller also runs as this role, and
  # an AccessDeniedException from Textract is treated as permanent (FAILED).
  depends_on = [aws_iam_role_policy.consumer_lambda_policy]
}

resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn = aws_sqs_queue.document_processing_queue.arn
  function_name    = aws_lambda_function.consumer_lambda.arn
  batch_size       = 1

  # Caps parallel Textract calls (the spend bound). Set on the poller rather
  # than via reserved_concurrent_executions: reserved concurrency makes the
  # poller over-receive and throttle, and each throttled receive counts toward
  # maxReceiveCount, pushing legitimate uploads to the DLQ. This just leaves
  # the extra messages queued. (2 is the minimum AWS allows.)
  scaling_config {
    maximum_concurrency = 2
  }
}