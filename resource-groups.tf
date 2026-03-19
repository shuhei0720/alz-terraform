# =============================================================================
# Resource Groups
# =============================================================================

# Management サブスクリプション: 監視基盤用
resource "azurerm_resource_group" "management" {
  provider = azurerm.management
  name     = "rg-management-${var.primary_location}"
  location = var.primary_location
  tags     = var.tags
}

# Connectivity サブスクリプション: Hub VNet 用（Hub ごとに 1 つ）
resource "azurerm_resource_group" "hub" {
  for_each = var.hub_virtual_networks
  provider = azurerm.connectivity
  name     = "rg-hub-${each.value.location}"
  location = each.value.location
  tags     = var.tags
}

# Connectivity サブスクリプション: Private DNS ゾーン用
resource "azurerm_resource_group" "dns" {
  count    = var.private_dns_enabled ? 1 : 0
  provider = azurerm.connectivity
  name     = "rg-dns-${var.primary_location}"
  location = var.primary_location
  tags     = var.tags
}

# Management サブスクリプション: AMBA アラート基盤用
# AMBA ポリシーが動的にタグを追加するため、tags のドリフトを無視
resource "azurerm_resource_group" "amba" {
  provider = azurerm.management
  name     = "rg-amba-alerts-${var.primary_location}"
  location = var.primary_location
  tags = {
    SHAPolicy_RG      = "true"
    _deployed_by_amba = "true"
  }

  lifecycle { ignore_changes = [tags] }
}
