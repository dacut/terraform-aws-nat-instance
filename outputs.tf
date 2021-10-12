output "eni_id" {
  description = "ID of the ENI for the NAT instance"
  value       = aws_network_interface.nat.id
}

output "eni_private_ip" {
  description = "Private IP of the ENI for the NAT instance"
  # workaround of https://github.com/terraform-providers/terraform-provider-aws/issues/7522
  value = tolist(aws_network_interface.nat.private_ips)[0]
}

output "public_ip" {
  description = "Public IP address of the ENI for the NAT instance"
  value = aws_eip.nat.public_ip
}

output "sg_id" {
  description = "ID of the security group of the NAT instance"
  value       = aws_security_group.nat.id
}

output "iam_role_name" {
  description = "Name of the IAM role for the NAT instance"
  value       = aws_iam_role.nat.name
}
