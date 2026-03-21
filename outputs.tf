# =============================================================================
# Management Groups
# =============================================================================

output "management_group_ids" {
  description = "管理グループ ID のマップ"
  value = {
    root           = azurerm_management_group.root.id
    platform       = azurerm_management_group.platform.id
    management     = azurerm_management_group.management.id
    connectivity   = azurerm_management_group.connectivity.id
    identity       = azurerm_management_group.identity.id
    security       = azurerm_management_group.security.id
    landing_zones  = azurerm_management_group.landing_zones.id
    corp           = azurerm_management_group.corp.id
    online         = azurerm_management_group.online.id
    sandbox        = azurerm_management_group.sandbox.id
    decommissioned = azurerm_management_group.decommissioned.id
  }
}

# =============================================================================
# Log Analytics
# =============================================================================

output "log_analytics_workspace_id" {
  description = "Log Analytics ワークスペースのリソース ID"
  value       = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_name" {
  description = "Log Analytics ワークスペース名"
  value       = azurerm_log_analytics_workspace.main.name
}

output "law_archive_storage_account_id" {
  description = "LAW アーカイブ用 Storage Account のリソース ID"
  value       = var.law_archive_retention_days > 0 ? azurerm_storage_account.law_archive[0].id : null
}

# =============================================================================
# Monitoring
# =============================================================================

output "ama_identity_id" {
  description = "Azure Monitor Agent 用 UAMI のリソース ID"
  value       = azurerm_user_assigned_identity.ama.id
}

output "ama_identity_principal_id" {
  description = "Azure Monitor Agent 用 UAMI のプリンシパル ID"
  value       = azurerm_user_assigned_identity.ama.principal_id
}

output "dcr_vm_insights_id" {
  description = "VM Insights Data Collection Rule のリソース ID"
  value       = azapi_resource.dcr_vm_insights.id
}

# =============================================================================
# Network
# =============================================================================

output "hub_virtual_network_ids" {
  description = "Hub VNet のリソース ID マップ"
  value = {
    for k, v in azurerm_virtual_network.hub : k => v.id
  }
}

output "hub_virtual_network_names" {
  description = "Hub VNet 名のマップ"
  value = {
    for k, v in azurerm_virtual_network.hub : k => v.name
  }
}

output "firewall_private_ips" {
  description = "Azure Firewall のプライベート IP アドレス"
  value = {
    for k, v in azurerm_firewall.hub : k => v.ip_configuration[0].private_ip_address
  }
}

output "firewall_public_ips" {
  description = "Azure Firewall のパブリック IP アドレス"
  value = {
    for k, v in azurerm_public_ip.firewall : k => v.ip_address
  }
}

output "route_table_ids" {
  description = "Spoke → Firewall ルートテーブルの ID マップ"
  value = {
    for k, v in azurerm_route_table.spoke_to_firewall : k => v.id
  }
}

output "er_circuit_ids" {
  description = "ExpressRoute Circuit の ID マップ"
  value = {
    for k, v in azurerm_express_route_circuit.hub : k => v.id
  }
}

output "er_gateway_ids" {
  description = "ExpressRoute Gateway の ID マップ"
  value = {
    for k, v in azurerm_virtual_network_gateway.er : k => v.id
  }
}

output "gateway_route_table_ids" {
  description = "GatewaySubnet ルートテーブルの ID マップ"
  value = {
    for k, v in azurerm_route_table.gateway : k => v.id
  }
}

# =============================================================================
# Subscription Vending
# =============================================================================

output "vending_virtual_network_ids" {
  description = "サブスクリプション自動発行で作成された VNet の ID マップ"
  value = {
    for k, v in azapi_resource.vending_vnet : k => v.id
  }
}

# =============================================================================
# Dashboard
# =============================================================================

output "ops_dashboard_id" {
  description = "基盤管理・運用ダッシュボード (Workbook) のリソース ID"
  value       = var.ops_dashboard_enabled ? azurerm_application_insights_workbook.ops[0].id : null
}
