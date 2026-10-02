locals {
  cloudflare_account_id = data.vault_kv_secret_v2.cloudflare.data["cloudflare_account_id"]
  cloudflare_api_token  = data.vault_kv_secret_v2.cloudflare.data["cloudflare_api_token"]
  mcp_api_key           = data.vault_kv_secret_v2.cloudflare.data["mcp"]

  # mTLS protected hostnames (Cloudflare Managed CA)
  # Excluded: status.0xk3m.dev, charts.0xk3m.dev, vault.0xk3m.dev, argocd.0xk3m.dev (has own auth)
  mtls_hostnames = ["grafana.0xk3m.dev", "argocd.0xk3m.dev", "proxmox.0xk3m.dev", "homepage.0xk3m.dev", "vault.0xk3m.dev", "chat.0xk3m.dev", "hubble.0xk3m.dev"]
}
