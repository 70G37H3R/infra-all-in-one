terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.33.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  assume_role {
    role_arn     = "arn:aws:iam::590183708030:role/DevOps-Terraform-Role"
    session_name = "terraform-session"
  }
}

# =====================
# VPC
# =====================
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "main-vpc"
  }
}

# =====================
# Subnet
# =====================
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-2"
  }
}
# =====================
# Internet Gateway
# =====================
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

# =====================
# Route Table
# =====================
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_assoc_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public_rt.id
}

# =====================
# Security Group
# =====================
resource "aws_security_group" "k3s_sg" {
  name   = "k3s-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["125.235.239.42/32"]
  }

  ingress {
    description = "HTTP for Ingress"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "K3s API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["125.235.239.42/32"]
  }

  ingress {
    description = "Allow all internal VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =====================
# EC2 Instances
# =====================
resource "aws_instance" "k3s" {
  count         = 2
  ami           = "ami-0b6c6ebed2801a5cb"
  instance_type = var.instance_type

  subnet_id = element([
    aws_subnet.public.id,
    aws_subnet.public_2.id
  ], count.index)

  vpc_security_group_ids      = [aws_security_group.k3s_sg.id]
  associate_public_ip_address = true
  key_name                    = "terraform-devops"

  user_data = count.index == 0 ? (
    <<-EOF
    #!/bin/bash
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ansible-core curl

    # Install Helm
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    EOF
  ) : null

  tags = {
    Name = "k3s-node-${count.index}"
  }
}

output "k3s_public_ips" {
  value = aws_instance.k3s[*].public_ip
}