provider "aws" {
  region = var.aws_region
}

# terraform {
#   backend "s3" {
#     bucket = ""
#     key    = "autotagging.tfstate"
#     region = "ap-southeast-1"
#   }
# }