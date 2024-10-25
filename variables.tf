variable "aws_region" {
  description = "The AWS region to deploy resources"
  type        = string
  default     = "ap-southeast-1"
}

variable "cost_center_value" {
  description = "Value for the CostCenter SSM parameter"
  type        = string
}

variable "department_value" {
  description = "Value for the Department SSM parameter"
  type        = string
}

variable "compliance_resource_types" {
  description = "List of AWS resource types to be monitored by AWS Config"
  type        = list(string)
  default     = ["AWS::SQS::Queue", "AWS::Events::Rule"]
}
