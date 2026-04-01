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

log_analytics_retention_days = 360  # LAW 内のデータ保持日数（KQL で即検索可能な期間）
sentinel_enabled             = true # Microsoft Sentinel（SIEM/SOAR）の有効化
law_archive_retention_days   = 2555 # アーカイブ保持日数（約 7 年 = コンプライアンス要件）

# =============================================================================
# Network
# =============================================================================

hub_virtual_networks = {
  primary = {
    location                            = "japaneast"
    address_space                       = ["10.0.0.0/22"] # Hub 用（1,024 IP）
    gateway_subnet_prefix               = "10.0.0.0/27"   # VPN/ER Gateway 用（Azure 推奨最小）
    bastion_subnet_prefix               = "10.0.0.64/26"  # Bastion 用（Azure 要件 /26 最小）
    firewall_subnet_prefix              = "10.0.1.0/26"   # Azure Firewall 用（Azure 要件 /26 最小）
    firewall_management_subnet_prefix   = null            # 強制トンネリング時のみ必要
    firewall_sku_tier                   = "Standard"
    firewall_threat_intel_mode          = "Deny"
    dns_resolver_inbound_subnet_prefix  = "10.0.2.0/28"  # Private DNS Resolver インバウンド
    dns_resolver_outbound_subnet_prefix = "10.0.2.16/28" # Private DNS Resolver アウトバウンド
    gateway_sku                         = "ErGw1AZ"      # ゾーン冗長 ER Gateway
    express_route = {
      service_provider_name = "Equinix"
      peering_location      = "Tokyo"
      bandwidth_in_mbps     = 50
      sku_tier              = "Standard"
      sku_family            = "MeteredData"
      connection_enabled    = false # キャリア開通後に true に変更
    }
  }
  secondary = {
    location                            = "japanwest"
    address_space                       = ["10.0.4.0/22"] # セカンダリ Hub 用
    gateway_subnet_prefix               = "10.0.4.0/27"
    bastion_subnet_prefix               = "10.0.4.64/26"
    firewall_subnet_prefix              = "10.0.5.0/26"
    firewall_management_subnet_prefix   = null
    firewall_sku_tier                   = "Standard"
    firewall_threat_intel_mode          = "Deny"
    dns_resolver_inbound_subnet_prefix  = "10.0.6.0/28"
    dns_resolver_outbound_subnet_prefix = "10.0.6.16/28"
    gateway_sku                         = "ErGw1AZ"
    express_route = {
      service_provider_name = "Equinix"
      peering_location      = "Osaka"
      bandwidth_in_mbps     = 50
      sku_tier              = "Standard"
      sku_family            = "MeteredData"
      connection_enabled    = false
    }
  }
}

# Spoke が接続する Hub キー。
# null（デフォルト）= 各 Spoke YAML の virtual_network.hub_key に従う
# "primary" or "secondary" = 全 Spoke を強制切替（DR オーバーライド）
active_hub_key = "secondary"

# =============================================================================
# DNS
# =============================================================================
# Private DNS はデフォルトで有効（55 ゾーン）。無効化する場合のみコメント解除。
# private_dns_enabled = false

# =============================================================================
# AMBA (Azure Monitor Baseline Alerts)
# =============================================================================

# グローバル通知先メールアドレス（基盤サブスクリプション + Service Health 通知）
# Spoke サブスクリプションの担当者通知は YAML の alert_contacts で定義。
amba_alert_email = ["platform-team@example.com"]

# =============================================================================
# Policy Exemptions
# =============================================================================

# Terraform state backend のストレージアカウントリソース ID
# ガードレール強制化に伴い、state SA を Storage/CMK ポリシーから免除する。
# 空文字の場合は免除を作成しない。
terraform_state_storage_account_id = "/subscriptions/bec80a1b-7f04-462d-9299-149138ee0e8a/resourceGroups/rg-terraform-state/providers/Microsoft.Storage/storageAccounts/stterraformstate061f34c4"

# =============================================================================
# Subscription Vending
# =============================================================================

# MCA (Microsoft Customer Agreement)
billing_scope_id = "/providers/Microsoft.Billing/billingAccounts/6d92e1a7-44ef-5b9d-fe85-600e31fecd27:7ffb2b72-d71a-46c2-ac74-10566d437c9e_2019-05-31/billingProfiles/KXVV-QQVV-BG7-PGB/invoiceSections/b5316415-c236-41e7-8237-fcf186346a73"
