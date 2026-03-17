# =============================================================================
# Log Analytics Workspace
# =============================================================================

resource "azurerm_log_analytics_workspace" "main" {
  provider            = azurerm.management
  name                = "law-management-${var.primary_location}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.management.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days

  allow_resource_only_permissions = true
  internet_ingestion_enabled      = true
  internet_query_enabled          = true
  local_authentication_enabled    = true

  tags = var.tags
}

# =============================================================================
# Microsoft Sentinel
# =============================================================================

# Sentinel オンボーディング（azapi — PUT は冪等、destroy 後の残存状態でも再作成可能）
resource "azapi_resource" "sentinel" {
  count     = var.sentinel_enabled ? 1 : 0
  type      = "Microsoft.SecurityInsights/onboardingStates@2024-03-01"
  name      = "default"
  parent_id = azurerm_log_analytics_workspace.main.id

  body = {
    properties = {
      customerManagedKey = false
    }
  }
}

# =============================================================================
# User Assigned Managed Identity (Azure Monitor Agent 用)
# =============================================================================

resource "azurerm_user_assigned_identity" "ama" {
  provider            = azurerm.management
  name                = "uami-ama-${var.primary_location}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.management.name
  tags                = var.tags
}

# AMBA アラート用 User Assigned Managed Identity
resource "azurerm_user_assigned_identity" "amba" {
  provider            = azurerm.management
  name                = "uami-amba-${var.primary_location}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.amba.name
  tags                = var.tags
}

# =============================================================================
# Data Collection Rule: VM パフォーマンス監視（azapi — InvalidPayload 自動リトライ対応）
# =============================================================================

resource "azapi_resource" "dcr_vm_insights" {
  type      = "Microsoft.Insights/dataCollectionRules@2023-03-11"
  name      = "dcr-vm-insights-${var.primary_location}"
  parent_id = azurerm_resource_group.management.id
  location  = var.primary_location
  tags      = var.tags

  # LAW テーブルのプロビジョニング完了前に作成すると InvalidPayload になる
  retry = {
    error_message_regex  = ["InvalidPayload", "Data collection rule is invalid"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }

  body = {
    properties = {
      description = "VM パフォーマンスデータを Log Analytics に収集"
      dataSources = {
        performanceCounters = [
          {
            name                        = "perfCounterDataSource"
            streams                     = ["Microsoft-Perf", "Microsoft-InsightsMetrics"]
            samplingFrequencyInSeconds   = 60
            counterSpecifiers = [
              "\\Processor Information(_Total)\\% Processor Time",
              "\\Memory\\Available Bytes",
              "\\LogicalDisk(_Total)\\% Free Space",
              "\\Network Interface(*)\\Bytes Total/sec",
            ]
          }
        ]
      }
      destinations = {
        logAnalytics = [
          {
            workspaceResourceId = azurerm_log_analytics_workspace.main.id
            name                = "la-destination"
          }
        ]
      }
      dataFlows = [
        {
          streams      = ["Microsoft-Perf", "Microsoft-InsightsMetrics"]
          destinations = ["la-destination"]
        }
      ]
    }
  }
}

# =============================================================================
# Change Tracking Solution（DCR が必要とするテーブルを LAW に作成）
# =============================================================================

resource "azurerm_log_analytics_solution" "change_tracking" {
  provider              = azurerm.management
  solution_name         = "ChangeTracking"
  location              = var.primary_location
  resource_group_name   = azurerm_resource_group.management.name
  workspace_resource_id = azurerm_log_analytics_workspace.main.id
  workspace_name        = azurerm_log_analytics_workspace.main.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/ChangeTracking"
  }
}

# =============================================================================
# Data Collection Rule: Change Tracking (azapi — extension データソースが必要)
# =============================================================================

resource "azapi_resource" "dcr_change_tracking" {
  type      = "Microsoft.Insights/dataCollectionRules@2021-04-01"
  name      = "dcr-change-tracking-${var.primary_location}"
  parent_id = azurerm_resource_group.management.id
  location  = var.primary_location
  tags      = var.tags

  retry = {
    error_message_regex  = ["InvalidOutputTable", "InvalidPayload"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }

  depends_on = [azurerm_log_analytics_solution.change_tracking]

  body = {
    properties = {
      description = "Change Tracking データを Log Analytics に収集"
      dataSources = {
        extensions = [
          {
            name          = "CTExtDataSource"
            extensionName = "ChangeTracking-Windows"
            streams       = ["Microsoft-ConfigurationChange", "Microsoft-ConfigurationChangeV2", "Microsoft-ConfigurationData"]
            extensionSettings = {
              enableFiles     = true
              enableSoftware  = true
              enableRegistry  = true
              enableServices  = true
              enableInventory = true
              registrySettings = {
                registryCollectionFrequency = 3000
                registryInfo = [
                  {
                    name        = "Registry_1"
                    groupTag    = "Recommended"
                    enabled     = false
                    recurse     = true
                    description = ""
                    keyName     = "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Group Policy\\Scripts\\Startup"
                    valueName   = ""
                  }
                ]
              }
              fileSettings = {
                fileCollectionFrequency = 2700
              }
              softwareSettings = {
                softwareCollectionFrequency = 1800
              }
              inventorySettings = {
                inventoryCollectionFrequency = 36000
              }
              servicesSettings = {
                serviceCollectionFrequency = 1800
              }
            }
          }
        ]
      }
      destinations = {
        logAnalytics = [
          {
            workspaceResourceId = azurerm_log_analytics_workspace.main.id
            name                = "LogAnalyticsDest"
          }
        ]
      }
      dataFlows = [
        {
          streams      = ["Microsoft-ConfigurationChange", "Microsoft-ConfigurationChangeV2", "Microsoft-ConfigurationData"]
          destinations = ["LogAnalyticsDest"]
        }
      ]
    }
  }
}

# =============================================================================
# Data Collection Rule: Defender for SQL (azapi — extension データソースが必要)
# =============================================================================

resource "azapi_resource" "dcr_defender_sql" {
  type      = "Microsoft.Insights/dataCollectionRules@2021-04-01"
  name      = "dcr-defender-sql-${var.primary_location}"
  parent_id = azurerm_resource_group.management.id
  location  = var.primary_location
  tags      = var.tags

  retry = {
    error_message_regex  = ["InvalidOutputTable", "InvalidPayload"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }

  body = {
    properties = {
      description = "Defender for SQL データを Log Analytics に収集"
      dataSources = {
        extensions = [
          {
            name          = "MicrosoftDefenderForSQL"
            extensionName = "MicrosoftDefenderForSQL"
            streams       = ["Microsoft-DefenderForSqlAlerts", "Microsoft-DefenderForSqlLogins", "Microsoft-DefenderForSqlTelemetry", "Microsoft-DefenderForSqlScanEvents", "Microsoft-DefenderForSqlScanResults", "Microsoft-SqlAtpStatus-DefenderForSql"]
            extensionSettings = {
              enableCollectionOfSqlQueriesForSecurityResearch = false
            }
          }
        ]
      }
      destinations = {
        logAnalytics = [
          {
            workspaceResourceId = azurerm_log_analytics_workspace.main.id
            name                = "LogAnalyticsDest"
          }
        ]
      }
      dataFlows = [
        {
          streams      = ["Microsoft-DefenderForSqlAlerts", "Microsoft-DefenderForSqlLogins", "Microsoft-DefenderForSqlTelemetry", "Microsoft-DefenderForSqlScanEvents", "Microsoft-DefenderForSqlScanResults", "Microsoft-SqlAtpStatus-DefenderForSql"]
          destinations = ["LogAnalyticsDest"]
        }
      ]
    }
  }
}
