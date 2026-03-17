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

# =============================================================================
# Network
# =============================================================================

variable "hub_virtual_networks" {
  description = "Hub VNet の設定マップ（キー名は任意、例: primary, secondary）"
  type = map(object({
    location                          = string
    address_space                     = list(string)
    gateway_subnet_prefix             = optional(string)
    bastion_subnet_prefix             = optional(string)
    firewall_subnet_prefix            = optional(string)
    firewall_management_subnet_prefix = optional(string)
    firewall_sku_tier                 = optional(string, "Standard")
    firewall_threat_intel_mode        = optional(string, "Deny")
    express_route = optional(object({
      service_provider_name = optional(string, "Equinix")
      peering_location      = optional(string, "Tokyo")
      bandwidth_in_mbps     = optional(number, 50)
      sku_tier              = optional(string, "Standard")
      sku_family            = optional(string, "MeteredData")
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
    "privatelink.adf.azure.com",                          # Data Factory
    "privatelink.afs.azure.net",                           # Azure File Sync
    "privatelink.agentsvc.azure-automation.net",           # Automation Agent
    "privatelink.api.azureml.ms",                          # Azure ML
    "privatelink.azconfig.io",                             # App Configuration
    "privatelink.azure-automation.net",                    # Automation Webhook/DSC
    "privatelink.azure-devices-provisioning.net",          # IoT DPS
    "privatelink.azure-devices.net",                       # IoT Hub
    "privatelink.azurecr.io",                              # Container Registry
    "privatelink.azuredatabricks.net",                     # Databricks
    "privatelink.azurehdinsight.net",                      # HDInsight
    "privatelink.azureiotcentral.com",                     # IoT Central
    "privatelink.azurewebsites.net",                       # App Service / Functions
    "privatelink.batch.azure.com",                         # Batch
    "privatelink.blob.core.windows.net",                   # Blob Storage
    "privatelink.cassandra.cosmos.azure.com",              # Cosmos DB Cassandra
    "privatelink.cognitiveservices.azure.com",             # Cognitive Services
    "privatelink.datafactory.azure.net",                   # Data Factory Portal
    "privatelink.dev.azuresynapse.net",                    # Synapse Dev
    "privatelink.dfs.core.windows.net",                    # Data Lake Storage Gen2
    "privatelink.directline.botframework.com",             # Bot Service DirectLine
    "privatelink.documents.azure.com",                     # Cosmos DB SQL API
    "privatelink.dp.kubernetesconfiguration.azure.com",    # Arc Kubernetes Config
    "privatelink.eventgrid.azure.net",                     # Event Grid
    "privatelink.file.core.windows.net",                   # File Storage
    "privatelink.grafana.azure.com",                       # Managed Grafana
    "privatelink.gremlin.cosmos.azure.com",                # Cosmos DB Gremlin
    "privatelink.guestconfiguration.azure.com",            # Guest Configuration
    "privatelink.his.arc.azure.com",                       # Arc Hybrid Identity
    "privatelink.japaneast.azmk8s.io",                     # AKS (japaneast)
    "privatelink.japaneast.kusto.windows.net",             # Kusto/ADX (japaneast)
    "privatelink.jpe.backup.windowsazure.com",             # Backup (japaneast)
    "japaneast.data.privatelink.azurecr.io",               # ACR Data (japaneast)
    "privatelink.media.azure.net",                         # Media Services
    "privatelink.mongo.cosmos.azure.com",                  # Cosmos DB MongoDB
    "privatelink.monitor.azure.com",                       # Azure Monitor
    "privatelink.notebooks.azure.net",                     # ML Notebooks
    "privatelink.ods.opinsights.azure.com",                # ODS (Log Analytics)
    "privatelink.oms.opinsights.azure.com",                # OMS (Log Analytics)
    "privatelink.prod.migration.windowsazure.com",         # Azure Migrate
    "privatelink.queue.core.windows.net",                  # Queue Storage
    "privatelink.redis.cache.windows.net",                 # Redis Cache
    "privatelink.search.windows.net",                      # Cognitive Search
    "privatelink.service.signalr.net",                     # SignalR
    "privatelink.servicebus.windows.net",                  # Service Bus
    "privatelink.siterecovery.windowsazure.com",           # Site Recovery
    "privatelink.sql.azuresynapse.net",                    # Synapse SQL
    "privatelink.table.core.windows.net",                  # Table Storage
    "privatelink.table.cosmos.azure.com",                  # Cosmos DB Table
    "privatelink.vaultcore.azure.net",                     # Key Vault
    "privatelink.web.core.windows.net",                    # Static Website Storage
    "privatelink.webpubsub.azure.com",                     # Web PubSub
    "privatelink.wvd.microsoft.com",                       # Azure Virtual Desktop
    # --- ALZ ポリシー外の追加ゾーン ---
    "privatelink.database.windows.net",                    # Azure SQL Database
    "privatelink.openai.azure.com",                        # Azure OpenAI
  ]
}

# =============================================================================
# AMBA
# =============================================================================

variable "amba_alert_email" {
  description = "AMBA アラート通知先メールアドレスのリスト（空リストの場合はメール通知なし）"
  type        = list(string)
  default     = []
}
