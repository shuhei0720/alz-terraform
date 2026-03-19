# =============================================================================
# Subscription Vending — YAML ファイルから自動的にサブスクリプションを発行
# =============================================================================
#
# 新しいサブスクリプションを追加する手順:
#   1. subscriptions/<name>.yaml にサブスクリプション定義を作成
#   2. terraform plan で確認、terraform apply で適用
#
# YAML を配置するだけで、provider alias や module ブロックの追加は不要。
# azapi プロバイダーがフルリソース ID により任意のサブスクリプションを操作する。
#
# 自動作成されるリソース:
#   - リソースグループ
#   - VNet + サブネット + NSG
#   - ルートテーブル（Firewall 経由、BGP 伝搬無効）
#   - Hub VNet へのピアリング（双方向）
#
# Spoke リソースの委任とプラットフォーム管理の分離:
#   ┌────────────────────────┬──────────────────────────────────────────┐
#   │ プラットフォーム管理    │ VNet DNS, Route Table, Peering, GW Route │
#   │ Spoke チーム委任        │ RG, VNet(DNS以外), NSG, Subnet, AG, ARP  │
#   └────────────────────────┴──────────────────────────────────────────┘
#   - VNet 本体は ignore_changes=all（アドレス空間等は Spoke チーム委任）
#   - DNS サーバーは azapi_update_resource で PATCH（DR 切替時に追跡）
#   - ルートテーブルは ignore_changes + PATCH で管理（DR 切替時にルート更新）
#   - ピアリングは replace_triggered_by で Hub 切替時に強制再作成
#
# =============================================================================

# --- YAML ファイルの読み込み ---

locals {
  subscription_yaml_files = var.subscription_vending_enabled ? fileset(var.subscription_vending_path, "*.yaml") : toset([])

  subscriptions = {
    for f in local.subscription_yaml_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${var.subscription_vending_path}/${f}"))
    if !startswith(f, "templates/")
  }

  # サブスクリプション新規作成が必要なもの（subscription_id 未指定）
  subscriptions_to_create = {
    for sub_key, sub in local.subscriptions : sub_key => sub
    if try(sub.subscription_id, null) == null
  }

  # 解決済みサブスクリプション ID（既存 or 新規作成）
  resolved_subscription_ids = {
    for sub_key, sub in local.subscriptions : sub_key =>
    try(sub.subscription_id, null) != null
    ? sub.subscription_id
    : azurerm_subscription.vending[sub_key].subscription_id
  }

  # 各サブスクリプションの派生値
  vending = {
    for sub_key, sub in local.subscriptions : sub_key => {
      sub_id       = local.resolved_subscription_ids[sub_key]
      tags         = merge(var.tags, try(sub.tags, {}))
      has_vnet     = sub.virtual_network != null
      has_firewall = length(local.hub_keys) > 0 && try(var.hub_virtual_networks[var.active_hub_key].firewall_subnet_prefix, null) != null
      has_peering  = try(sub.virtual_network.hub_peering_enabled, false) && length(local.hub_keys) > 0
      vnet_rg      = try(sub.virtual_network.resource_group_name, "")
      subnets = {
        for s in try(sub.virtual_network.subnets, []) :
        s.name => s
      }
    }
  }

  # サブネット — フラットなマップに展開（sub_key/subnet_name → {...}）
  vending_subnets = merge([
    for sub_key, v in local.vending : {
      for sname, s in v.subnets :
      "${sub_key}/${sname}" => merge(s, {
        sub_key = sub_key
        sub_id  = v.sub_id
        vnet_rg = v.vnet_rg
      })
    } if v.has_vnet
  ]...)

  # リソースグループ — フラットなマップに展開
  vending_resource_groups = merge([
    for sub_key, sub in local.subscriptions : {
      for rg_key, rg in try(sub.resource_groups, {}) :
      "${sub_key}/${rg_key}" => merge(rg, {
        sub_key = sub_key
        sub_id  = local.resolved_subscription_ids[sub_key]
        tags    = local.vending[sub_key].tags
      })
    }
  ]...)

  # VNet があるサブスクリプション
  vending_with_vnet = {
    for sub_key, v in local.vending : sub_key => v if v.has_vnet
  }

  # VNet + Firewall があるサブスクリプション
  vending_with_route_table = {
    for sub_key, v in local.vending : sub_key => v if v.has_vnet && v.has_firewall
  }

  # ピアリングが有効なサブスクリプション
  vending_with_peering = {
    for sub_key, v in local.vending : sub_key => v if v.has_vnet && v.has_peering
  }

  # GatewaySubnet ルートテーブルに追加する Vending Spoke VNet ルート
  vending_spoke_routes = flatten([
    for sub_key, sub in local.subscriptions : [
      for i, cidr in try(sub.virtual_network.address_space, []) : {
        key            = "${sub_key}-${i}"
        name           = "to-${sub.virtual_network.name}-${i}"
        address_prefix = cidr
      }
    ] if try(sub.virtual_network.hub_peering_enabled, false)
  ])

  # firewall_rules が定義されているサブスクリプション
  vending_with_firewall_rules = {
    for sub_key, sub in local.subscriptions : sub_key => {
      network_rules     = try(sub.firewall_rules.network_rules, [])
      application_rules = try(sub.firewall_rules.application_rules, [])
    }
    if try(sub.firewall_rules, null) != null
  }

  # alert_contacts が定義されている Spoke サブスクリプション（アラートルーティング用）
  vending_with_alerts = {
    for sub_key, sub in local.subscriptions : sub_key => {
      sub_id         = local.resolved_subscription_ids[sub_key]
      display_name   = sub.display_name
      location       = sub.location
      alert_contacts = sub.alert_contacts
      short_name     = substr(replace(sub_key, "-", ""), 0, 12)
    }
    if try(length(sub.alert_contacts), 0) > 0
  }
}

# =============================================================================
# Subscription Creation — subscription_id 未指定の YAML → 新規作成
# =============================================================================
#
# YAML に subscription_id を記載しない場合、azurerm_subscription でサブスクリプションを
# 新規作成します。billing_scope_id 変数が必須です。
#
# 既存サブスクリプションを使う場合は、YAML に subscription_id を記載するだけで
# このリソースはスキップされます。
#
# 注意:
#   - subscription_id は apply 後に初めて判明します（plan 時は unknown）
#   - Azure API の結果整合性のため、作成後 30 秒の待機が入ります
#   - terraform destroy 時のサブスクリプション誤キャンセル防止のため
#     prevent_cancellation_on_destroy = true を設定しています（terraform.tf）
# =============================================================================

resource "azurerm_subscription" "vending" {
  for_each = local.subscriptions_to_create

  subscription_name = each.value.display_name
  alias             = "${var.root_id}-${each.key}"
  billing_scope_id  = var.billing_scope_id
  workload          = try(each.value.workload_type, "Production")
  tags              = merge(var.tags, try(each.value.tags, {}))
}

# サブスクリプション作成後の API 伝搬待機（結果整合性対策）
resource "time_sleep" "wait_for_subscription" {
  for_each = local.subscriptions_to_create

  depends_on      = [azurerm_subscription.vending]
  create_duration = "30s"
}

# =============================================================================
# Management Group Association — 新規作成したサブスクリプションを MG に配置
# =============================================================================

resource "azurerm_management_group_subscription_association" "vending" {
  for_each = local.subscriptions_to_create

  management_group_id = "/providers/Microsoft.Management/managementGroups/${var.root_id}-${each.value.management_group_id}"
  subscription_id     = "/subscriptions/${azurerm_subscription.vending[each.key].subscription_id}"
}

# =============================================================================
# Resource Groups
# =============================================================================

resource "azapi_resource" "vending_resource_groups" {
  for_each = local.vending_resource_groups

  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = each.value.name
  parent_id = "/subscriptions/${each.value.sub_id}"
  location  = each.value.location
  tags      = each.value.tags

  depends_on = [time_sleep.wait_for_subscription]

  lifecycle { ignore_changes = all }
}

# =============================================================================
# VNet
# =============================================================================

resource "azapi_resource" "vending_vnet" {
  for_each = local.vending_with_vnet

  type      = "Microsoft.Network/virtualNetworks@2024-01-01"
  name      = local.subscriptions[each.key].virtual_network.name
  parent_id = "/subscriptions/${each.value.sub_id}/resourceGroups/${each.value.vnet_rg}"
  location  = local.subscriptions[each.key].location
  tags      = each.value.tags

  body = {
    properties = {
      addressSpace = {
        addressPrefixes = local.subscriptions[each.key].virtual_network.address_space
      }
      dhcpOptions = {
        dnsServers = [
          azurerm_private_dns_resolver_inbound_endpoint.hub[var.active_hub_key].ip_configurations[0].private_ip_address
        ]
      }
    }
  }

  depends_on = [
    azapi_resource.vending_resource_groups,
    azurerm_private_dns_resolver_inbound_endpoint.hub
  ]

  lifecycle { ignore_changes = all }
}

# --- Spoke VNet DNS サーバー管理（プラットフォーム管理 — DR 切替追跡） ---
# VNet 本体は ignore_changes=all で委任しつつ、DNS サーバー設定だけを
# azapi_update_resource（PATCH）で継続管理する。active_hub_key の切替時に
# Spoke VNet の DNS サーバーがセカンダリ Hub の Resolver に自動更新される。
resource "azapi_update_resource" "vending_vnet_dns" {
  for_each = local.vending_with_vnet

  type        = "Microsoft.Network/virtualNetworks@2024-01-01"
  resource_id = azapi_resource.vending_vnet[each.key].id

  body = {
    properties = {
      dhcpOptions = {
        dnsServers = [
          azurerm_private_dns_resolver_inbound_endpoint.hub[var.active_hub_key].ip_configurations[0].private_ip_address
        ]
      }
    }
  }

  depends_on = [azapi_resource.vending_vnet]
}

# =============================================================================
# NSG（サブネットごとに 1 つ）
# =============================================================================

resource "azapi_resource" "vending_nsgs" {
  for_each = local.vending_subnets

  type      = "Microsoft.Network/networkSecurityGroups@2024-01-01"
  name      = "nsg-${each.value.name}"
  parent_id = "/subscriptions/${each.value.sub_id}/resourceGroups/${each.value.vnet_rg}"
  location  = local.subscriptions[each.value.sub_key].location
  tags      = var.tags

  body = {
    properties = {
      securityRules = []
    }
  }

  depends_on = [azapi_resource.vending_resource_groups]

  lifecycle { ignore_changes = all }
}

# =============================================================================
# Route Table — 0.0.0.0/0 → Firewall, BGP 伝搬無効
# =============================================================================

resource "azapi_resource" "vending_route_table" {
  for_each = local.vending_with_route_table

  type      = "Microsoft.Network/routeTables@2024-01-01"
  name      = "rt-${local.subscriptions[each.key].virtual_network.name}"
  parent_id = "/subscriptions/${each.value.sub_id}/resourceGroups/${each.value.vnet_rg}"
  location  = local.subscriptions[each.key].location
  tags      = var.tags

  body = {
    properties = {
      disableBgpRoutePropagation = true
      routes = [
        {
          name = "default-to-firewall"
          properties = {
            addressPrefix    = "0.0.0.0/0"
            nextHopType      = "VirtualAppliance"
            nextHopIpAddress = azurerm_firewall.hub[var.active_hub_key].ip_configuration[0].private_ip_address
          }
        }
      ]
    }
  }

  depends_on = [azapi_resource.vending_resource_groups]

  # ルート変更は azapi_update_resource（PATCH）で管理。
  # azapi_resource の Update は "Missing Resource Identity" バグがあるため
  # body のインプレース更新を回避する。
  lifecycle { ignore_changes = [body] }
}

# --- Spoke Route Table ルート管理（プラットフォーム管理 — DR 切替追跡） ---
# Route Table 本体は ignore_changes=[body] で初回作成後は更新しない。
# デフォルトルート（0.0.0.0/0 → Firewall）は PATCH で継続管理し、
# active_hub_key の切替時にルートが自動更新される。
# PATCH は routes 配列を上書きするため、手動追加された不正ルートも排除される。
resource "azapi_update_resource" "vending_route_table_routes" {
  for_each = local.vending_with_route_table

  type        = "Microsoft.Network/routeTables@2024-01-01"
  resource_id = azapi_resource.vending_route_table[each.key].id

  body = {
    properties = {
      routes = [
        {
          name = "default-to-firewall"
          properties = {
            addressPrefix    = "0.0.0.0/0"
            nextHopType      = "VirtualAppliance"
            nextHopIpAddress = azurerm_firewall.hub[var.active_hub_key].ip_configuration[0].private_ip_address
          }
        }
      ]
    }
  }

  depends_on = [azapi_resource.vending_route_table]
}

# =============================================================================
# Subnets（NSG + Route Table を properties で直接関連付け）
# =============================================================================

resource "azapi_resource" "vending_subnets" {
  for_each = local.vending_subnets

  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = each.value.name
  parent_id = azapi_resource.vending_vnet[each.value.sub_key].id

  body = {
    properties = merge(
      {
        addressPrefix = each.value.address_prefix
        networkSecurityGroup = {
          id = azapi_resource.vending_nsgs[each.key].id
        }
      },
      local.vending[each.value.sub_key].has_firewall ? {
        routeTable = {
          id = azapi_resource.vending_route_table[each.value.sub_key].id
        }
      } : {}
    )
  }

  retry = {
    error_message_regex  = ["AnotherOperationInProgress", "InUseSubnetCannotBeUpdated"]
    interval_seconds     = 10
    max_interval_seconds = 60
  }

  lifecycle { ignore_changes = all }
}

# =============================================================================
# Spoke → Hub Peering
# =============================================================================

resource "azapi_resource" "vending_spoke_to_hub" {
  for_each = local.vending_with_peering

  type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01"
  name      = "peer-${local.subscriptions[each.key].virtual_network.name}-to-hub"
  parent_id = azapi_resource.vending_vnet[each.key].id

  body = {
    properties = {
      remoteVirtualNetwork = {
        id = azurerm_virtual_network.hub[var.active_hub_key].id
      }
      allowForwardedTraffic     = true
      allowVirtualNetworkAccess = true
      useRemoteGateways         = try(local.subscriptions[each.key].virtual_network.use_hub_gateway, false)
    }
  }

  retry = {
    error_message_regex  = ["ReferencedResourceNotProvisioned", "InUseSubnetCannotBeUpdated", "AnotherOperationInProgress", "RemoteVnetHasNoGateways"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }

  # use_hub_gateway=true の場合、ER Gateway 完成後でないとピアリング不可
  depends_on = [azurerm_virtual_network_gateway.er]

  # Azure は remoteVirtualNetwork のインプレース変更を禁止する
  # (ChangingRemoteVirtualNetworkNotAllowed)。active_hub_key 切替時に
  # 自動で delete → recreate させる。
  lifecycle {
    replace_triggered_by = [azurerm_virtual_network.hub[var.active_hub_key].id]
  }
}

# =============================================================================
# Hub → Spoke Peering
# =============================================================================

resource "azapi_resource" "vending_hub_to_spoke" {
  for_each = local.vending_with_peering

  type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01"
  name      = "peer-hub-to-${local.subscriptions[each.key].virtual_network.name}"
  parent_id = azurerm_virtual_network.hub[var.active_hub_key].id

  body = {
    properties = {
      remoteVirtualNetwork = {
        id = azapi_resource.vending_vnet[each.key].id
      }
      allowForwardedTraffic     = true
      allowVirtualNetworkAccess = true
      allowGatewayTransit       = true
    }
  }

  retry = {
    error_message_regex  = ["ReferencedResourceNotProvisioned", "InUseSubnetCannotBeUpdated", "AnotherOperationInProgress"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }
}

# =============================================================================
# GatewaySubnet ルートテーブルに Vending Spoke VNet 行きルートを追加
# =============================================================================

resource "azurerm_route" "gateway_to_vending" {
  for_each = length(local.hub_keys) > 0 ? {
    for r in local.vending_spoke_routes : r.key => r
  } : {}
  provider               = azurerm.connectivity
  name                   = each.value.name
  resource_group_name    = azurerm_resource_group.hub[var.active_hub_key].name
  route_table_name       = azurerm_route_table.gateway[var.active_hub_key].name
  address_prefix         = each.value.address_prefix
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.hub[var.active_hub_key].ip_configuration[0].private_ip_address
}

# =============================================================================
# Spoke サブスクリプション別アラート通知（Action Group + Alert Processing Rule）
# =============================================================================
#
# YAML の alert_contacts に通知先を定義すると、払い出し時に以下を自動作成:
#   1. リソースグループ（Spoke サブスクリプション内）
#   2. Action Group（通知先メールアドレス）
#   3. Alert Processing Rule（スコープ = Spoke サブスクリプション全体）
#
# ARP は同一サブスクリプション内のリソースしかスコープにできないため、
# AG・ARP ともに Spoke サブスクリプション側に配置します。
#
# 基盤サブスクリプション（management, connectivity, identity, security）は
# AMBA デフォルト AG（amba_alert_email）で通知されるため対象外です。
# =============================================================================

resource "azapi_resource" "spoke_amba_rg" {
  for_each = local.vending_with_alerts

  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = "rg-amba-alerts-${each.value.location}"
  parent_id = "/subscriptions/${each.value.sub_id}"
  location  = each.value.location
  tags = {
    _deployed_by_amba = "true"
  }

  lifecycle { ignore_changes = all }
}

resource "azapi_resource" "spoke_action_group" {
  for_each = local.vending_with_alerts

  type      = "Microsoft.Insights/actionGroups@2023-01-01"
  name      = "ag-amba-${each.key}"
  parent_id = azapi_resource.spoke_amba_rg[each.key].id
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

  lifecycle { ignore_changes = all }
}

resource "azapi_resource" "spoke_alert_processing_rule" {
  for_each = local.vending_with_alerts

  type      = "Microsoft.AlertsManagement/actionRules@2021-08-08"
  name      = "apr-amba-${each.key}"
  parent_id = azapi_resource.spoke_amba_rg[each.key].id
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

  lifecycle { ignore_changes = all }
}
