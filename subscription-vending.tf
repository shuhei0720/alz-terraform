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
# =============================================================================

# --- YAML ファイルの読み込み ---

locals {
  subscription_yaml_files = var.subscription_vending_enabled ? fileset(var.subscription_vending_path, "*.yaml") : toset([])

  subscriptions = {
    for f in local.subscription_yaml_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${var.subscription_vending_path}/${f}"))
    if !startswith(f, "templates/")
  }

  # 各サブスクリプションの派生値
  vending = {
    for sub_key, sub in local.subscriptions : sub_key => {
      sub_id       = sub.subscription_id
      tags         = merge(var.tags, try(sub.tags, {}))
      has_vnet     = sub.virtual_network != null
      has_firewall = length(local.hub_keys) > 0 && try(var.hub_virtual_networks[local.hub_keys[0]].firewall_subnet_prefix, null) != null
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
        sub_id  = sub.subscription_id
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
    }
  }

  depends_on = [azapi_resource.vending_resource_groups]
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
            nextHopIpAddress = azurerm_firewall.hub[local.hub_keys[0]].ip_configuration[0].private_ip_address
          }
        }
      ]
    }
  }

  depends_on = [azapi_resource.vending_resource_groups]
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
        id = azurerm_virtual_network.hub[local.hub_keys[0]].id
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
}

# =============================================================================
# Hub → Spoke Peering
# =============================================================================

resource "azapi_resource" "vending_hub_to_spoke" {
  for_each = local.vending_with_peering

  type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01"
  name      = "peer-hub-to-${local.subscriptions[each.key].virtual_network.name}"
  parent_id = azurerm_virtual_network.hub[local.hub_keys[0]].id

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
  resource_group_name    = azurerm_resource_group.hub[local.hub_keys[0]].name
  route_table_name       = azurerm_route_table.gateway[local.hub_keys[0]].name
  address_prefix         = each.value.address_prefix
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.hub[local.hub_keys[0]].ip_configuration[0].private_ip_address
}
