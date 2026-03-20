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

log_analytics_retention_days = 360
sentinel_enabled             = true
law_archive_retention_days   = 2555  # 約7年（コンプライアンス要件）

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
  secondary = {
    location                            = "japanwest"
    address_space                       = ["10.1.0.0/16"]
    gateway_subnet_prefix               = "10.1.0.0/27"
    bastion_subnet_prefix               = "10.1.1.0/26"
    firewall_subnet_prefix              = "10.1.2.0/26"
    firewall_management_subnet_prefix   = null
    dns_resolver_inbound_subnet_prefix  = "10.1.3.0/26"
    dns_resolver_outbound_subnet_prefix = "10.1.4.0/26"
    firewall_sku_tier                   = "Standard"
    firewall_threat_intel_mode          = "Deny"
  }
}

# Spoke が接続する Hub キー。
# null（デフォルト）= 各 Spoke YAML の virtual_network.hub_key に従う
# "primary" or "secondary" = 全 Spoke を強制切替（DR オーバーライド）
active_hub_key = "secondary"

# =============================================================================
# DNS
# =============================================================================
# Private DNS はデフォルトで有効。無効化する場合は 以下をコメント解除。
# private_dns_enabled = false
#
# デフォルトで 56 個の Azure Private Link DNS ゾーンが作成されます。
# ゾーン一覧は variables.tf の private_dns_zones を参照。
#
# カスタマイズ例:
#
#   1. ゾーンを追加する場合:
#      variables.tf の private_dns_zones の default リストに追加してください。
#
#   2. 特定のゾーンだけ使う場合:
#      全デフォルトを上書きしたい場合のみ、ここで private_dns_zones を指定。
#      private_dns_zones = [
#        "privatelink.blob.core.windows.net",
#        "privatelink.database.windows.net",
#        "privatelink.vaultcore.azure.net",
#      ]
#
#   3. リージョン固有ゾーンについて:
#      以下の 4 ゾーンは japaneast 固有です。
#      primary_location を変更する場合は variables.tf で置換が必要です。
#        - privatelink.japaneast.azmk8s.io
#        - privatelink.japaneast.kusto.windows.net
#        - privatelink.jpe.backup.windowsazure.com
#        - japaneast.data.privatelink.azurecr.io

# =============================================================================
# AMBA (Azure Monitor Baseline Alerts)
# =============================================================================

amba_alert_email = ["platform-team@example.com"]

# =============================================================================
# Subscription Vending
# =============================================================================

# MCA (Microsoft Customer Agreement)
billing_scope_id = "/providers/Microsoft.Billing/billingAccounts/6d92e1a7-44ef-5b9d-fe85-600e31fecd27:7ffb2b72-d71a-46c2-ac74-10566d437c9e_2019-05-31/billingProfiles/KXVV-QQVV-BG7-PGB/invoiceSections/b5316415-c236-41e7-8237-fcf186346a73"
