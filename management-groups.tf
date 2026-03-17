# =============================================================================
# Management Group Hierarchy
# =============================================================================
#
#   Tenant Root Group
#   └── Root (var.root_id)
#       ├── Platform
#       │   ├── Management      ← Management サブスクリプション
#       │   ├── Connectivity    ← Connectivity サブスクリプション
#       │   ├── Identity        ← Identity サブスクリプション
#       │   └── Security        ← Security サブスクリプション
#       ├── Landing Zones
#       │   ├── Corp            ← 社内ワークロード用
#       │   └── Online          ← インターネット公開ワークロード用
#       ├── Sandbox             ← テスト・PoC 用
#       └── Decommissioned      ← 廃止予定リソース用
#
# =============================================================================

# --- Root ---

resource "azurerm_management_group" "root" {
  name                       = var.root_id
  display_name               = var.root_name
  parent_management_group_id = "/providers/Microsoft.Management/managementGroups/${data.azurerm_client_config.current.tenant_id}"
}

# Azure API 内部で MG 伝搬が完了するまで待機（子 MG 作成時の 404 回避）
resource "time_sleep" "wait_for_root_mg" {
  depends_on      = [azurerm_management_group.root]
  create_duration = "30s"
}

# --- Platform ---

resource "azurerm_management_group" "platform" {
  name                       = "${var.root_id}-platform"
  display_name               = "Platform"
  parent_management_group_id = azurerm_management_group.root.id
  depends_on                 = [time_sleep.wait_for_root_mg]
}

resource "azurerm_management_group" "management" {
  name                       = "${var.root_id}-management"
  display_name               = "Management"
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "connectivity" {
  name                       = "${var.root_id}-connectivity"
  display_name               = "Connectivity"
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "identity" {
  name                       = "${var.root_id}-identity"
  display_name               = "Identity"
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "security" {
  name                       = "${var.root_id}-security"
  display_name               = "Security"
  parent_management_group_id = azurerm_management_group.platform.id
}

# --- Landing Zones ---

resource "azurerm_management_group" "landing_zones" {
  name                       = "${var.root_id}-landingzones"
  display_name               = "Landing Zones"
  parent_management_group_id = azurerm_management_group.root.id
  depends_on                 = [time_sleep.wait_for_root_mg]
}

resource "azurerm_management_group" "corp" {
  name                       = "${var.root_id}-corp"
  display_name               = "Corp"
  parent_management_group_id = azurerm_management_group.landing_zones.id
}

resource "azurerm_management_group" "online" {
  name                       = "${var.root_id}-online"
  display_name               = "Online"
  parent_management_group_id = azurerm_management_group.landing_zones.id
}

# --- Sandbox & Decommissioned ---

resource "azurerm_management_group" "sandbox" {
  name                       = "${var.root_id}-sandbox"
  display_name               = "Sandbox"
  parent_management_group_id = azurerm_management_group.root.id
  depends_on                 = [time_sleep.wait_for_root_mg]
}

resource "azurerm_management_group" "decommissioned" {
  name                       = "${var.root_id}-decommissioned"
  display_name               = "Decommissioned"
  parent_management_group_id = azurerm_management_group.root.id
  depends_on                 = [time_sleep.wait_for_root_mg]
}

# =============================================================================
# Subscription → Management Group Association
# =============================================================================

resource "azurerm_management_group_subscription_association" "management" {
  management_group_id = azurerm_management_group.management.id
  subscription_id     = "/subscriptions/${var.subscription_ids["management"]}"
}

resource "azurerm_management_group_subscription_association" "connectivity" {
  management_group_id = azurerm_management_group.connectivity.id
  subscription_id     = "/subscriptions/${var.subscription_ids["connectivity"]}"
}

resource "azurerm_management_group_subscription_association" "identity" {
  management_group_id = azurerm_management_group.identity.id
  subscription_id     = "/subscriptions/${var.subscription_ids["identity"]}"
}

resource "azurerm_management_group_subscription_association" "security" {
  management_group_id = azurerm_management_group.security.id
  subscription_id     = "/subscriptions/${var.subscription_ids["security"]}"
}
