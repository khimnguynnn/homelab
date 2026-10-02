# Cloudflare Access for dsh.0xk3m.dev
# Uses SSO for browser users + Service Token for app internal calls

resource "cloudflare_zero_trust_access_application" "dsh" {
  zone_id          = data.cloudflare_zone.homelab.id
  name             = "DeepSeek Harness"
  domain           = "dsh.0xk3m.dev"
  type             = "self_hosted"
  session_duration = "24h"
  skip_interstitial = true
}

# Service Token for app internal API calls
resource "cloudflare_zero_trust_access_service_token" "dsh" {
  account_id = local.cloudflare_account_id
  name       = "dsh-internal"
  duration   = "forever"
}

# Reusable Policy: Allow SSO users (email domain)
resource "cloudflare_zero_trust_access_policy" "dsh_sso" {
  account_id = local.cloudflare_account_id
  name       = "DSH Allow SSO users"
  decision   = "allow"

  include = [
    {
      email_domain = {
        domain = "0xk3m.dev"
      }
    },
    {
      email_domain = {
        domain = "namitech.io"
      }
    }
  ]
}

# Reusable Policy: Allow Service Token (for app internal calls)
resource "cloudflare_zero_trust_access_policy" "dsh_service_token" {
  account_id = local.cloudflare_account_id
  name       = "DSH Allow Service Token"
  decision   = "non_identity"

  include = [
    {
      service_token = {
        token_id = cloudflare_zero_trust_access_service_token.dsh.id
      }
    }
  ]
}

# Link policies to application
resource "cloudflare_zero_trust_access_application_policy" "dsh_sso" {
  application_id = cloudflare_zero_trust_access_application.dsh.id
  zone_id        = data.cloudflare_zone.homelab.id
  policy_id      = cloudflare_zero_trust_access_policy.dsh_sso.id
  precedence     = 1
}

resource "cloudflare_zero_trust_access_application_policy" "dsh_service_token" {
  application_id = cloudflare_zero_trust_access_application.dsh.id
  zone_id        = data.cloudflare_zone.homelab.id
  policy_id      = cloudflare_zero_trust_access_policy.dsh_service_token.id
  precedence     = 2
}
