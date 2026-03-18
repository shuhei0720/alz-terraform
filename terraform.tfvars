# =============================================================================
# Core Settings
# =============================================================================

root_id   = "alz"
root_name = "Azure Landing Zones"

primary_location = "japaneast"

subscription_ids = {
  management   = "bec80a1b-7f04-462d-9299-149138ee0e8a"
  connectivity = "727b2d68-0dc6-4c7b-9f89-67645c4ac077"
  identity     = "54769692-ff09-4294-bcce-0cd28e5f4646"
  security     = "ee22eea6-5c25-4941-b81a-05c3403b9002"
}

tags = {
  deployed_by = "terraform"
  environment = "production"
  managed_by  = "platform-team"
}

# =============================================================================
# Management Resources
# =============================================================================

log_analytics_retention_days = 30
sentinel_enabled             = true

# =============================================================================
# Network
# =============================================================================

hub_virtual_networks = {
  primary = {
    location                            = "japaneast"
    address_space                       = ["10.0.0.0/16"]
    gateway_subnet_prefix               = "10.0.0.0/27" # VPN/ER Gateway 用
    bastion_subnet_prefix               = "10.0.1.0/26" # Bastion 用
    firewall_subnet_prefix              = "10.0.2.0/26" # Azure Firewall 用 (/26 最小)
    firewall_management_subnet_prefix   = null          # 強制トンネリング時のみ必要
    dns_resolver_inbound_subnet_prefix  = "10.0.3.0/26" # DNSインバウンドエンドポイント用
    dns_resolver_outbound_subnet_prefix = "10.0.4.0/26" # DNSアウトバウンドエンドポイント用
    firewall_sku_tier                   = "Standard"
    firewall_threat_intel_mode          = "Deny"
  }
  # セカンダリリージョンが必要な場合はコメントを解除
  # secondary = {
  #   location                          = "japanwest"
  #   address_space                     = ["10.1.0.0/16"]
  #   gateway_subnet_prefix             = "10.1.0.0/27"
  #   bastion_subnet_prefix             = "10.1.1.0/26"
  #   firewall_subnet_prefix            = "10.1.2.0/26"
  #   firewall_management_subnet_prefix = null
  #   dns_resolver_inbound_subnet_prefix = "10.1.3.0/26"
  #   dns_resolver_outbound_subnet_prefix = "10.1.4.0/26"
  #   firewall_sku_tier                 = "Standard"
  #   firewall_threat_intel_mode        = "Deny"
  # }
}

# =============================================================================
# DNS
# =============================================================================

private_dns_enabled = true

# デフォルトで主要な Azure Private Link DNS ゾーンが含まれます。
# カスタマイズする場合は以下のように指定:
# private_dns_zones = [
#   "privatelink.blob.core.windows.net",
#   "privatelink.database.windows.net",
#   "privatelink.vaultcore.azure.net",
# ]
