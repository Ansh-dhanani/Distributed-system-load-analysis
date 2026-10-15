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
  description = "Ubuntu 24.04 LTS AMI in ap-south-1 (update as needed)"
  type        = string
  default     = "ami-065d2b03fb493085a"
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
