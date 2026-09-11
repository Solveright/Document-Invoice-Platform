resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-${var.environment}-lambda-role"

  assume_role_policy = jsonencode({
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

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_app_policy" {
  name = "${var.project_name}-${var.environment}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [
          aws_sqs_queue.document_processing_queue.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
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
  function_name = "${var.project_name}-${var.environment}-api"
  role          = aws_iam_role.lambda_role.arn
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
}

resource "aws_lambda_function" "consumer_lambda" {
  function_name = "${var.project_name}-${var.environment}-consumer"
  role          = aws_iam_role.lambda_role.arn
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
}

resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn = aws_sqs_queue.document_processing_queue.arn
  function_name    = aws_lambda_function.consumer_lambda.arn
  batch_size       = 1
}