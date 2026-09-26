output "static_ip" {
  value       = aws_lightsail_static_ip.proxy.ip_address
  description = "Public static IP of the proxy. Point your DNS A record here."
}

output "ssh_command" {
  value       = "ssh -i <keyfile> ubuntu@${aws_lightsail_static_ip.proxy.ip_address}"
  description = "SSH template; replace <keyfile> with the saved private key path."
}

output "domain_hint" {
  value       = "Create DNS A ${var.domain_name} -> ${aws_lightsail_static_ip.proxy.ip_address}"
  description = "DNS record required before Hysteria2 ACME http-01 can issue a cert."
}

output "ssh_private_key_pem" {
  value       = aws_lightsail_key_pair.main.private_key
  sensitive   = true
  description = "One-time retrieval: tofu output -raw ssh_private_key_pem > ~/.ssh/china-proxy.pem && chmod 600 ~/.ssh/china-proxy.pem"
}
