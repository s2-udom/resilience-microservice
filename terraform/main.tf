resource "aws_ecr_repository" "resilience_app" {
  name                 = "resilience-microservice"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # Good for dissertation testing
}

output "repository_url" {
  value = aws_ecr_repository.resilience_app.repository_url
} 