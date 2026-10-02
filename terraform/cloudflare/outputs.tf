output "tunnel_id" {
  description = "ID of the 0xk3m-homelabs tunnel"
  value       = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

output "tunnel_cname" {
  description = "CNAME target to point DNS records at this tunnel"
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
}

output "tunnel_token" {
  description = "Token used to run cloudflared for this tunnel"
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.homelab.token
  sensitive   = true
}

output "tunnel_ingress_api_token" {
  description = "API token for the cloudflare-tunnel-ingress-controller"
  value       = cloudflare_account_token.tunnel_ingress.value
  sensitive   = true
}

output "dsh_service_token_client_id" {
  description = "CF-Access-Client-Id for dsh internal API calls"
  value       = cloudflare_zero_trust_access_service_token.dsh.client_id
  sensitive   = true
}

output "dsh_service_token_client_secret" {
  description = "CF-Access-Client-Secret for dsh internal API calls"
  value       = cloudflare_zero_trust_access_service_token.dsh.client_secret
  sensitive   = true
}
