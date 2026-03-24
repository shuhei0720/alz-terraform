# =============================================================================
# Private Link DNS Zones（azapi — 409 Conflict 自動リトライ対応）
# =============================================================================

resource "azapi_resource" "private_dns_zone" {
  for_each  = var.private_dns_enabled ? var.private_dns_zones : toset([])
  type      = "Microsoft.Network/privateDnsZones@2024-06-01"
  name      = each.value
  parent_id = azurerm_resource_group.dns[0].id
  location  = "global"
  tags      = var.tags

  # 同一 RG 内の大量 DNS Zone 同時作成で Azure API が 409 を返すことがある
  retry = {
    error_message_regex  = ["Conflict", "Another operation is pending"]
    interval_seconds     = 10
    max_interval_seconds = 60
  }
}

# 各 Private DNS ゾーン → 各 Hub VNet へのリンク（名前解決用）
resource "azurerm_private_dns_zone_virtual_network_link" "private_link" {
  for_each              = local.dns_zone_vnet_links
  provider              = azurerm.connectivity
  name                  = "link-${each.value.hub_key}"
  resource_group_name   = azurerm_resource_group.dns[0].name
  private_dns_zone_name = azapi_resource.private_dns_zone[each.value.zone_name].name
  virtual_network_id    = azurerm_virtual_network.hub[each.value.hub_key].id
  registration_enabled  = false
  resolution_policy     = "NxDomainRedirect"
  tags                  = var.tags
}

# =============================================================================
# Auto-Registration DNS Zones（Hub VNet ごと）
# =============================================================================

# VM 名の自動 DNS 登録用ゾーン（例: japaneast.azure.local）
resource "azurerm_private_dns_zone" "auto_registration" {
  for_each            = var.private_dns_enabled ? var.hub_virtual_networks : {}
  provider            = azurerm.connectivity
  name                = "${each.value.location}.azure.local"
  resource_group_name = azurerm_resource_group.dns[0].name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "auto_registration" {
  for_each              = var.private_dns_enabled ? var.hub_virtual_networks : {}
  provider              = azurerm.connectivity
  name                  = "link-${each.key}-autoreg"
  resource_group_name   = azurerm_resource_group.dns[0].name
  private_dns_zone_name = azurerm_private_dns_zone.auto_registration[each.key].name
  virtual_network_id    = azurerm_virtual_network.hub[each.key].id
  registration_enabled  = true
  tags                  = var.tags
}
