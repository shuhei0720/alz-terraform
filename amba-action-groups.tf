# =============================================================================
# Spoke サブスクリプション別アラート通知（Action Group + Alert Processing Rule）
# =============================================================================
#
# Spoke サブスクリプション YAML の alert_contacts に通知先を定義すると、
# 払い出し時に以下を自動作成します:
#
#   1. Action Group（通知先メールアドレス）→ 管理サブの rg-amba-alerts-* に集中配置
#   2. Alert Processing Rule（スコープ = Spoke サブスクリプション全体）
#      → 対象サブスクのアラートを担当者の AG にルーティング
#
# 基盤サブスクリプション（management, connectivity, identity, security）は
# AMBA デフォルト AG（amba_alert_email）で通知されるため対象外です。
#
# =============================================================================

locals {
  # alert_contacts が定義されている Spoke サブスクリプションのみ抽出
  vending_with_alerts = {
    for sub_key, sub in local.subscriptions : sub_key => {
      sub_id         = sub.subscription_id
      display_name   = sub.display_name
      alert_contacts = sub.alert_contacts
      short_name     = substr(replace(sub_key, "-", ""), 0, 12)
    }
    if try(length(sub.alert_contacts), 0) > 0
  }
}

# --- Action Group（Spoke サブスクリプション別） ---

resource "azapi_resource" "spoke_action_group" {
  for_each = local.vending_with_alerts

  type      = "Microsoft.Insights/actionGroups@2023-01-01"
  name      = "ag-amba-${each.key}"
  parent_id = azurerm_resource_group.amba.id
  location  = "global"
  tags      = var.tags

  body = {
    properties = {
      groupShortName = each.value.short_name
      enabled        = true
      emailReceivers = [
        for contact in each.value.alert_contacts : {
          name                 = contact.name
          emailAddress         = contact.email_address
          useCommonAlertSchema = true
        }
      ]
    }
  }
}

# --- Alert Processing Rule（Spoke サブスクリプション → AG ルーティング） ---

resource "azapi_resource" "spoke_alert_processing_rule" {
  for_each = local.vending_with_alerts

  type      = "Microsoft.AlertsManagement/actionRules@2021-08-08"
  name      = "apr-amba-${each.key}"
  parent_id = azurerm_resource_group.amba.id
  location  = "global"
  tags      = var.tags

  body = {
    properties = {
      description = "${each.value.display_name} のアラートを ag-amba-${each.key} にルーティング"
      enabled     = true
      scopes      = ["/subscriptions/${each.value.sub_id}"]
      actions = [
        {
          actionType     = "AddActionGroups"
          actionGroupIds = [azapi_resource.spoke_action_group[each.key].id]
        }
      ]
    }
  }
}
