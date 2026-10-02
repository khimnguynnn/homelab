# Cloudflare Access for dsh.0xk3m.dev
# Uses SSO for browser users + Service Token for app internal calls

# Service Token for app internal API calls
resource "cloudflare_zero_trust_access_service_token" "dsh" {
  account_id = local.cloudflare_account_id
  name       = "dsh-internal"
  duration   = "forever"
}

# Access Application with inline policies
resource "cloudflare_zero_trust_access_application" "dsh" {
  zone_id           = data.cloudflare_zone.homelab.id
  name              = "DeepSeek Harness"
  domain            = "dsh.0xk3m.dev"
  type              = "self_hosted"
  session_duration  = "24h"
  skip_interstitial = true

  policies = [
    {
      name     = "Allow SSO users"
      decision = "allow"
      include = [
        {
          email = {
            email = "khimnguynn@gmail.com"
          }
        }
      ]
    },
    {
      name     = "Allow Service Token"
      decision = "non_identity"
      include = [
        {
          service_token = {
            token_id = cloudflare_zero_trust_access_service_token.dsh.id
          }
        }
      ]
    }
  ]
}
