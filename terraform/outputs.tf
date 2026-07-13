output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.node.id
}

output "region" {
  description = "AWS region the node runs in"
  value       = var.region
}

output "public_ip" {
  description = "Public IPv4 of the node (changes on stop/start)"
  value       = aws_instance.node.public_ip
}

output "public_dns" {
  description = "Public DNS name of the node"
  value       = aws_instance.node.public_dns
}

output "ssm_start_session" {
  description = "Open a shell without SSH via Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.node.id} --region ${var.region}"
}

output "db_secret_name" {
  description = "Secrets Manager name holding the Postgres credentials"
  value       = aws_secretsmanager_secret.db.name
}

output "kms_key_arn" {
  description = "CMK used for Secrets Manager and EBS encryption"
  value       = aws_kms_key.main.arn
}

output "security_group_id" {
  description = "Security group attached to the node"
  value       = aws_security_group.node.id
}
