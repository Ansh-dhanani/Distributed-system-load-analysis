variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "az" {
  type    = string
  default = "ap-south-1a"
}

variable "key_name" {
  type    = string
  default = "k8s-lab-key"
}

variable "ami_id" {
  description = "AMI id. Leave empty to auto-select the latest Ubuntu 24.04 LTS amd64 image in var.region."
  type        = string
  default     = ""
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "worker_count" {
  type    = number
  default = 2
}

variable "root_volume_gb" {
  type    = number
  default = 16
}

variable "allowed_ssh_cidr" {
  type    = string
  default = "0.0.0.0/0"
}
