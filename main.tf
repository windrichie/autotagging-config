# Config Rule
resource "aws_config_config_rule" "autotagging_required_tags_rule" {
  name        = "autotagging-required-tags-rule"
  description = "A custom rule to check for required tags"

  source {
    owner             = "CUSTOM_LAMBDA"
    source_identifier = aws_lambda_function.config_autotagging_rule_detector.arn
    source_detail {
      message_type = "ConfigurationItemChangeNotification"
    }
    source_detail {
      message_type = "OversizedConfigurationItemChangeNotification"
    }
  }

  scope {
    compliance_resource_types = var.compliance_resource_types
  }

  depends_on = [aws_lambda_permission.function_config_autotagging_rule_detector]
}

## SSM Parameter
resource "aws_ssm_parameter" "cost_center" {
  name  = "/auto-tagging/mandatory/CostCenter"
  type  = "String"
  value = var.cost_center_value

  description = "Mandatory CostCenter tag value for auto-tagging"
}

resource "aws_ssm_parameter" "department" {
  name  = "/auto-tagging/mandatory/Department"
  type  = "String"
  value = var.department_value

  description = "Mandatory Department tag value for auto-tagging"
}


## Detector resources
data "archive_file" "config_rule_detector_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/config-rule-detector"
  output_path = "${path.module}/lambda/config-rule-detector.zip"
}

resource "aws_lambda_function" "config_autotagging_rule_detector" {
  filename         = data.archive_file.config_rule_detector_lambda_zip.output_path
  function_name    = "config-autotagging-rule-detector"
  role             = aws_iam_role.config_autotagging_rule_detector_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  memory_size      = 128
  timeout          = 30
  architectures    = ["arm64"]
  reserved_concurrent_executions = 10
  dead_letter_config {
    target_arn = aws_sqs_queue.remediation_dlq.arn
  }

}

resource "aws_lambda_permission" "function_config_autotagging_rule_detector" {
  statement_id  = "AllowConfigInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.config_autotagging_rule_detector.arn
  principal     = "config.amazonaws.com"
  source_arn = aws_config_config_rule.autotagging_required_tags_rule.arn
}

resource "aws_iam_role" "config_autotagging_rule_detector_role" {
  path               = "/service-role/"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "config_autotagging_rule_detector_role_lambda_basic_execution_detector" {
  role       = aws_iam_role.config_autotagging_rule_detector_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "config_autotagging_rule_detector_role_ssm_config_permissions" {
  name = "ssm_config_permissions"
  role = aws_iam_role.config_autotagging_rule_detector_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/auto-tagging/*"
      },
      {
        Effect = "Allow"
        Action = "config:PutEvaluations"
        Resource = "*"
      }
    ]
  })
}

## Remediation resources
resource "aws_cloudwatch_event_rule" "config_autotagging_remediation_rule" {
  name = "config-autotagging-remediation-rule"
  description = "Config Autotagging Remediation Rule"
  state = "ENABLED"

  event_pattern = jsonencode({
    "detail-type": ["Config Rules Compliance Change"],
    "source": ["aws.config"],
    "detail": {
      "messageType": ["ComplianceChangeNotification"],
      "configRuleName": ["autotagging-required-tags-rule"],
      "newEvaluationResult": {
        "complianceType": ["NON_COMPLIANT"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "to_sqs" {
  rule      = aws_cloudwatch_event_rule.config_autotagging_remediation_rule.name
  target_id = "SendToSQS"
  arn       = aws_sqs_queue.remediation_queue.arn
}

resource "aws_sqs_queue" "remediation_queue" {
  name                      = "config-autotagging-remediation-queue"
  delay_seconds             = 0
  message_retention_seconds = 1209600  # 14 days
  receive_wait_time_seconds = 20
  visibility_timeout_seconds = 360  # 6 minutes, should be greater than Lambda function timeout
  kms_master_key_id = "alias/aws/sqs"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.remediation_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "allow_eventbridge" {
  queue_url = aws_sqs_queue.remediation_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.remediation_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.config_autotagging_remediation_rule.arn
          }
        }
      }
    ]
  })
}

resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.remediation_queue.arn
  function_name    = aws_lambda_function.config_autotagging_rule_remediation.arn
  batch_size       = 5
  maximum_batching_window_in_seconds = 30  # Wait up to 30 seconds to gather messages
  scaling_config {
    maximum_concurrency = 5  # Allow up to 5 concurrent Lambda invocations
  }
}

resource "aws_sqs_queue" "remediation_dlq" {
  name = "config-autotagging-remediation-dlq"
  kms_master_key_id = "alias/aws/sqs"
}

data "archive_file" "config_rule_remediation_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/config-rule-remediation"
  output_path = "${path.module}/lambda/config-rule-remediation.zip"
}

resource "aws_lambda_function" "config_autotagging_rule_remediation" {
  filename         = data.archive_file.config_rule_remediation_lambda_zip.output_path
  function_name    = "config-autotagging-rule-remediation"
  role             = aws_iam_role.config_autotagging_rule_remediation_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  memory_size      = 128
  timeout          = 300
  architectures    = ["arm64"]
  reserved_concurrent_executions = 5
  dead_letter_config {
    target_arn = aws_sqs_queue.remediation_dlq.arn
  }
}

resource "aws_iam_role" "config_autotagging_rule_remediation_role" {
  path               = "/service-role/"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "config_autotagging_rule_remediation_role_lambda_basic_execution" {
  role       = aws_iam_role.config_autotagging_rule_remediation_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "config_autotagging_rule_remediation_role_resource_tagging_api" {
  role       = aws_iam_role.config_autotagging_rule_remediation_role.name
  policy_arn = "arn:aws:iam::aws:policy/ResourceGroupsTaggingAPITagUntagSupportedResources"
}

resource "aws_iam_role_policy" "config_autotagging_rule_remediation_role_custom_remediation_permissions" {
  role = aws_iam_role.config_autotagging_rule_remediation_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/auto-tagging/*"
      },
      {
        Effect = "Allow"
        Action = "config:GetResourceConfigHistory"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "events:ListTagsForResource",
          "events:TagResource"
        ]
        Resource = "arn:aws:events:*:*:rule/*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.remediation_queue.arn
      }
    ]
  })
}