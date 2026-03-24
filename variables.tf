# =============================================================================
# Core Settings
# =============================================================================

variable "root_id" {
  description = "ルート管理グループの ID（命名プレフィックスとしても使用）"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{2,24}$", var.root_id))
    error_message = "root_id は 2〜24 文字の英数字とハイフンで指定してください。"
  }
}

variable "root_name" {
  description = "ルート管理グループの表示名"
  type        = string
}

variable "primary_location" {
  description = "プライマリリージョン"
  type        = string
  default     = "japaneast"
}

variable "subscription_ids" {
  description = "各プラットフォームサブスクリプションの ID"
  type        = map(string)

  validation {
    condition = alltrue([
      for key in ["management", "connectivity", "identity", "security"] :
      contains(keys(var.subscription_ids), key)
    ])
    error_message = "subscription_ids には management, connectivity, identity, security のキーがすべて必要です。"
  }
}

variable "tags" {
  description = "全リソースに適用する共通タグ"
  type        = map(string)
  default = {
    deployed_by = "terraform"
  }
}

# =============================================================================
# Management Resources
# =============================================================================

variable "log_analytics_retention_days" {
  description = "Log Analytics ワークスペースのデータ保持日数"
  type        = number
  default     = 30

  validation {
    condition     = var.log_analytics_retention_days >= 30 && var.log_analytics_retention_days <= 730
    error_message = "保持日数は 30〜730 の範囲で指定してください。"
  }
}

variable "sentinel_enabled" {
  description = "Microsoft Sentinel を有効化するか"
  type        = bool
  default     = true
}

variable "law_archive_retention_days" {
  description = "LAW ログの Blob アーカイブ保持日数。0 = アーカイブ無効"
  type        = number
  default     = 0

  validation {
    condition     = var.law_archive_retention_days >= 0
    error_message = "保持日数は 0 以上で指定してください。0 = アーカイブ無効。"
  }
}

variable "law_archive_export_tables" {
  description = "Data Export Rule でエクスポートするテーブル名のリスト"
  type        = list(string)
  default = [
    # --- セキュリティ・コンプライアンス（監査必須）---
    "SecurityEvent",                   # Windows セキュリティイベント（ログオン、権限変更等）
    "SecurityAlert",                   # Defender 各種アラート
    "SecurityIncident",                # セキュリティインシデント（Sentinel）
    "CommonSecurityLog",               # CEF 形式のセキュリティログ（ファイアウォール、IDS 等）
    "AzureActivity",                   # Azure 管理操作の監査ログ（ARM 操作全件）
    "SigninLogs",                      # Entra ID サインインログ（対話型）
    "AADNonInteractiveUserSignInLogs", # Entra ID 非対話型サインイン
    "AADServicePrincipalSignInLogs",   # サービスプリンシパルのサインイン
    "AADManagedIdentitySignInLogs",    # マネージド ID のサインイン
    "AuditLogs",                       # Entra ID 監査ログ（ユーザー・グループ変更等）
    "AADProvisioningLogs",             # Entra ID プロビジョニングログ（アプリ・HR 連携）
    # --- Azure Firewall（ALZ ハブ コアコンポーネント）---
    "AZFWNetworkRule",     # Firewall ネットワークルール処理（許可/拒否）
    "AZFWApplicationRule", # Firewall アプリケーションルール処理（FQDN ベース）
    "AZFWNatRule",         # Firewall NAT/DNAT ルール処理
    "AZFWThreatIntel",     # Firewall 脅威インテリジェンスによるブロック
    "AZFWIdpsSignature",   # Firewall IDPS（侵入検知・防止）検出
    "AZFWDnsQuery",        # Firewall DNS プロキシクエリログ
    # --- DNS ---
    "DnsEvents",    # DNS クエリ・応答イベント（DNS トンネリング検出にも有用）
    "DnsInventory", # DNS サーバーインベントリ
    # --- 構成管理・変更追跡 ---
    "ConfigurationChange", # OS 構成変更の検出結果
    "ConfigurationData",   # OS 構成ベースライン
    # --- オペレーション・監視 ---
    "Heartbeat",       # エージェント死活監視
    "Perf",            # VM パフォーマンスカウンター
    "InsightsMetrics", # VM Insights メトリクス
    "VMConnection",    # VM 間ネットワーク接続データ（Service Map / 横展開検出）
    "Event",           # Windows イベントログ（Application, System）
    "Syslog",          # Linux syslog
    "W3CIISLog",       # IIS アクセスログ
    # --- 更新管理 ---
    "Update",        # 利用可能な更新プログラム
    "UpdateSummary", # パッチコンプライアンス状況
    # --- Azure リソース診断 ---
    "AzureDiagnostics", # Azure リソースの診断ログ（NSG, Key Vault, SQL 等）
    "AzureMetrics",     # Azure リソースメトリクス
    # --- Defender ---
    "ProtectionStatus",            # マルウェア対策の状態
    "ThreatIntelligenceIndicator", # 脅威インテリジェンス IOC
  ]
}

# =============================================================================
# Network
# =============================================================================

variable "active_hub_key" {
  description = <<-EOT
    DR 一括切替用の Hub キー。
    null（デフォルト）= 各 Spoke YAML の virtual_network.hub_key に従ってピアリング先を決定。
    値を指定すると全 Spoke を強制的にそのHub へ切り替え（DR オーバーライド）。
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.active_hub_key == null ? true : contains(keys(var.hub_virtual_networks), var.active_hub_key)
    error_message = "active_hub_key は null または hub_virtual_networks のキー名と一致する必要があります。"
  }
}

variable "hub_virtual_networks" {
  description = "Hub VNet の設定マップ（キー名は任意、例: primary, secondary）"
  type = map(object({
    location                            = string
    address_space                       = list(string)
    gateway_subnet_prefix               = optional(string)
    bastion_subnet_prefix               = optional(string)
    bastion_sku                         = optional(string, "Standard")
    firewall_subnet_prefix              = optional(string)
    firewall_management_subnet_prefix   = optional(string)
    dns_resolver_inbound_subnet_prefix  = optional(string)
    dns_resolver_outbound_subnet_prefix = optional(string)
    firewall_sku_tier                   = optional(string, "Standard")
    firewall_threat_intel_mode          = optional(string, "Deny")
    gateway_sku                         = optional(string, "ErGw1AZ")
    express_route = optional(object({
      service_provider_name = optional(string, "Equinix")
      peering_location      = optional(string, "Tokyo")
      bandwidth_in_mbps     = optional(number, 50)
      sku_tier              = optional(string, "Standard")
      sku_family            = optional(string, "MeteredData")
      connection_enabled    = optional(bool, false)
    }), {})
  }))
  default = {}
}

# =============================================================================
# Spoke VNets (ワークロード用)
# =============================================================================

variable "spoke_virtual_networks" {
  description = "Spoke VNet の設定マップ（キー名は任意）"
  type = map(object({
    location            = string
    address_space       = list(string)
    hub_key             = string
    resource_group_name = string
    subscription_id     = optional(string)
    subnets = optional(map(object({
      address_prefix = string
    })), {})
  }))
  default = {}
}

# =============================================================================
# Subscription Vending
# =============================================================================

variable "subscription_vending_enabled" {
  description = "YAML ベースのサブスクリプション自動発行を有効化するか"
  type        = bool
  default     = true
}

variable "subscription_vending_path" {
  description = "サブスクリプション定義 YAML ファイルのディレクトリパス"
  type        = string
  default     = "./subscriptions"
}

variable "billing_scope_id" {
  description = <<-EOT
    サブスクリプション新規作成時の課金スコープ ID。
    YAML に subscription_id が未指定のサブスクリプションがある場合に必須。

    EA:  /providers/Microsoft.Billing/billingAccounts/{billingAccountName}/enrollmentAccounts/{enrollmentAccountName}
    MCA: /providers/Microsoft.Billing/billingAccounts/{billingAccountName}/billingProfiles/{billingProfileName}/invoiceSections/{invoiceSectionName}
  EOT
  type        = string
  default     = null

  validation {
    condition = (
      var.billing_scope_id == null ||
      can(regex("^/providers/Microsoft.Billing/billingAccounts/.+", var.billing_scope_id))
    )
    error_message = "billing_scope_id は /providers/Microsoft.Billing/billingAccounts/ で始まる必要があります。"
  }
}

# =============================================================================
# DNS
# =============================================================================

variable "private_dns_enabled" {
  description = "Private DNS ゾーンを作成するか"
  type        = bool
  default     = true
}

variable "private_dns_zones" {
  description = "作成する Azure Private Link DNS ゾーンの一覧（ALZ Deploy-Private-DNS-Zones ポリシー準拠 + 追加分）"
  type        = set(string)
  default = [
    # --- ALZ Deploy-Private-DNS-Zones ポリシーが参照する 50 ゾーン ---
    # ※ 一部のゾーンはリージョン固有（japaneast）。リージョン変更時は要修正。
    "privatelink.adf.azure.com",                        # Data Factory
    "privatelink.afs.azure.net",                        # Azure File Sync
    "privatelink.agentsvc.azure-automation.net",        # Automation Agent
    "privatelink.api.azureml.ms",                       # Azure ML
    "privatelink.azconfig.io",                          # App Configuration
    "privatelink.azure-automation.net",                 # Automation Webhook/DSC
    "privatelink.azure-devices-provisioning.net",       # IoT DPS
    "privatelink.azure-devices.net",                    # IoT Hub
    "privatelink.azurecr.io",                           # Container Registry
    "privatelink.azuredatabricks.net",                  # Databricks
    "privatelink.azurehdinsight.net",                   # HDInsight
    "privatelink.azureiotcentral.com",                  # IoT Central
    "privatelink.azurewebsites.net",                    # App Service / Functions
    "privatelink.batch.azure.com",                      # Batch
    "privatelink.blob.core.windows.net",                # Blob Storage
    "privatelink.cassandra.cosmos.azure.com",           # Cosmos DB Cassandra
    "privatelink.cognitiveservices.azure.com",          # Cognitive Services
    "privatelink.datafactory.azure.net",                # Data Factory Portal
    "privatelink.dev.azuresynapse.net",                 # Synapse Dev
    "privatelink.dfs.core.windows.net",                 # Data Lake Storage Gen2
    "privatelink.directline.botframework.com",          # Bot Service DirectLine
    "privatelink.documents.azure.com",                  # Cosmos DB SQL API
    "privatelink.dp.kubernetesconfiguration.azure.com", # Arc Kubernetes Config
    "privatelink.eventgrid.azure.net",                  # Event Grid
    "privatelink.file.core.windows.net",                # File Storage
    "privatelink.grafana.azure.com",                    # Managed Grafana
    "privatelink.gremlin.cosmos.azure.com",             # Cosmos DB Gremlin
    "privatelink.guestconfiguration.azure.com",         # Guest Configuration
    "privatelink.his.arc.azure.com",                    # Arc Hybrid Identity
    "privatelink.japaneast.azmk8s.io",                  # AKS (japaneast)
    "privatelink.japaneast.kusto.windows.net",          # Kusto/ADX (japaneast)
    "privatelink.jpe.backup.windowsazure.com",          # Backup (japaneast)
    "japaneast.data.privatelink.azurecr.io",            # ACR Data (japaneast)
    "privatelink.media.azure.net",                      # Media Services
    "privatelink.mongo.cosmos.azure.com",               # Cosmos DB MongoDB
    "privatelink.monitor.azure.com",                    # Azure Monitor
    "privatelink.notebooks.azure.net",                  # ML Notebooks
    "privatelink.ods.opinsights.azure.com",             # ODS (Log Analytics)
    "privatelink.oms.opinsights.azure.com",             # OMS (Log Analytics)
    "privatelink.prod.migration.windowsazure.com",      # Azure Migrate
    "privatelink.queue.core.windows.net",               # Queue Storage
    "privatelink.redis.cache.windows.net",              # Redis Cache
    "privatelink.search.windows.net",                   # Cognitive Search
    "privatelink.service.signalr.net",                  # SignalR
    "privatelink.servicebus.windows.net",               # Service Bus
    "privatelink.siterecovery.windowsazure.com",        # Site Recovery
    "privatelink.sql.azuresynapse.net",                 # Synapse SQL
    "privatelink.table.core.windows.net",               # Table Storage
    "privatelink.table.cosmos.azure.com",               # Cosmos DB Table
    "privatelink.vaultcore.azure.net",                  # Key Vault
    "privatelink.web.core.windows.net",                 # Static Website Storage
    "privatelink.webpubsub.azure.com",                  # Web PubSub
    "privatelink.wvd.microsoft.com",                    # Azure Virtual Desktop
    # --- ALZ ポリシー外の追加ゾーン ---
    "privatelink.database.windows.net", # Azure SQL Database
    "privatelink.openai.azure.com",     # Azure OpenAI
  ]
}

# =============================================================================
# AMBA
# =============================================================================

variable "amba_alert_email" {
  description = "AMBA アラート通知先メールアドレスのリスト（基盤サブスクリプション向け + Service Health 通知）"
  type        = list(string)
  default     = []
}

# =============================================================================
# Policy Exemptions
# =============================================================================

variable "terraform_state_storage_account_id" {
  description = "Terraform state backend のストレージアカウントリソース ID（ポリシー免除用）。空の場合は免除を作成しない"
  type        = string
  default     = ""
}
