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

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.document_processing_queue.url
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

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.documents.name
    }
  }
}

resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn = aws_sqs_queue.document_processing_queue.arn
  function_name    = aws_lambda_function.consumer_lambda.arn
  batch_size       = 1
}