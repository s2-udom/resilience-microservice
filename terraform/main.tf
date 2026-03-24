resource "aws_ecr_repository" "resilience_app" {
  name                 = "resilience-microservice"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # Good for dissertation testing
}

output "repository_url" {
  value = aws_ecr_repository.resilience_app.repository_url
} 
# 1. The VPC (Your private slice of AWS)
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "resilience-vpc"
  }
}

# 2. Public Subnet (Where the "Receptionist" / Load Balancer lives)
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "eu-west-2a"

  tags = {
    Name = "resilience-public-1"
  }
}

# 3. Internet Gateway (The "Front Door" to the web)
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "resilience-igw"
  }
}

# 4. Route Table (The "Map" telling traffic where to go)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

# 5. Connect the Map to the Subnet
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}
# The ECS Cluster 
resource "aws_ecs_cluster" "main" {
  name = "resilience-cluster"
}

# Security Group (The Firewall)
resource "aws_security_group" "ecs_sg" {
  name        = "resilience-ecs-sg"
  vpc_id      = aws_vpc.main.id

  # Allow incoming traffic on port 8000 
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outgoing traffic so the app can talk to ECR/Internet
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# IAM Role for ECS to "Talk" to ECR
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "resilience-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}


# 1. Ask AWS to find the policy by NAME instead of ARN
data "aws_iam_policy" "ecs_task_execution" {
  name = "AmazonECSTaskExecutionRolePolicy"
}

# 2. Attach it using the found object
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = data.aws_iam_policy.ecs_task_execution.arn
}
# The Task Definition (The Blueprint)
resource "aws_ecs_task_definition" "app" {
  family                   = "resilience-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256" # 0.25 vCPU
  memory                   = "512" # 0.5 GB RAM
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "resilience-app"
      image     = "317356818920.dkr.ecr.eu-west-2.amazonaws.com/resilience-microservice:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
        }
      ]
    }
  ])
}
# The ECS Service 
resource "aws_ecs_service" "main" {
  name            = "resilience-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public_1.id]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
}