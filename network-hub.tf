# =============================================================================
# Hub Virtual Networks
# =============================================================================

resource "azurerm_virtual_network" "hub" {
  for_each            = var.hub_virtual_networks
  provider            = azurerm.connectivity
  name                = "vnet-hub-${each.value.location}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name
  address_space       = each.value.address_space
  tags                = var.tags
}

# =============================================================================
# Hub Subnets
# =============================================================================

# GatewaySubnet — VPN/ExpressRoute Gateway 用
resource "azurerm_subnet" "gateway" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.gateway_subnet_prefix != null
  }
  provider             = azurerm.connectivity
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.hub[each.key].name
  virtual_network_name = azurerm_virtual_network.hub[each.key].name
  address_prefixes     = [each.value.gateway_subnet_prefix]
}

# AzureBastionSubnet — Bastion 用
resource "azurerm_subnet" "bastion" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.bastion_subnet_prefix != null
  }
  provider             = azurerm.connectivity
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.hub[each.key].name
  virtual_network_name = azurerm_virtual_network.hub[each.key].name
  address_prefixes     = [each.value.bastion_subnet_prefix]
}

# AzureFirewallSubnet — Azure Firewall 用
resource "azurerm_subnet" "firewall" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.firewall_subnet_prefix != null
  }
  provider             = azurerm.connectivity
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub[each.key].name
  virtual_network_name = azurerm_virtual_network.hub[each.key].name
  address_prefixes     = [each.value.firewall_subnet_prefix]
}

# AzureFirewallManagementSubnet — Firewall 管理トラフィック用（Basic SKU / 強制トンネリング時）
resource "azurerm_subnet" "firewall_management" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.firewall_management_subnet_prefix != null
  }
  provider             = azurerm.connectivity
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.hub[each.key].name
  virtual_network_name = azurerm_virtual_network.hub[each.key].name
  address_prefixes     = [each.value.firewall_management_subnet_prefix]
}

# InboundEndpointSubnet — プライベートDNSリゾルバ インバウンドエンドポイント用
resource "azurerm_subnet" "dns_resolver_inbound" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.dns_resolver_inbound_subnet_prefix != null
  }
  provider             = azurerm.connectivity
  name                 = "InboundEndpointSubnet"
  resource_group_name  = azurerm_resource_group.hub[each.key].name
  virtual_network_name = azurerm_virtual_network.hub[each.key].name
  address_prefixes     = [each.value.dns_resolver_inbound_subnet_prefix]

  delegation {
    name = "Microsoft.Network.dnsResolvers"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# OutboundEndpointSubnet — プライベートDNSリゾルバ アウトバウンドエンドポイント用
resource "azurerm_subnet" "dns_resolver_outbound" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.dns_resolver_outbound_subnet_prefix != null
  }
  provider             = azurerm.connectivity
  name                 = "OutboundEndpointSubnet"
  resource_group_name  = azurerm_resource_group.hub[each.key].name
  virtual_network_name = azurerm_virtual_network.hub[each.key].name
  address_prefixes     = [each.value.dns_resolver_outbound_subnet_prefix]

  delegation {
    name = "Microsoft.Network.dnsResolvers"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# =============================================================================
# Azure Firewall Policy
# =============================================================================

resource "azurerm_firewall_policy" "hub" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.firewall_subnet_prefix != null
  }
  provider                 = azurerm.connectivity
  name                     = "fwp-hub-${each.value.location}"
  location                 = each.value.location
  resource_group_name      = azurerm_resource_group.hub[each.key].name
  sku                      = each.value.firewall_sku_tier
  threat_intelligence_mode = each.value.firewall_threat_intel_mode

  dns {
    proxy_enabled = true
  }

  tags = var.tags
}

# デフォルト許可ルール: 全 Spoke 共通
resource "azurerm_firewall_policy_rule_collection_group" "hub_default" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.firewall_subnet_prefix != null
  }
  provider           = azurerm.connectivity
  name               = "DefaultRuleCollectionGroup"
  firewall_policy_id = azurerm_firewall_policy.hub[each.key].id
  priority           = 200

  # ===== ネットワークルール =====

  network_rule_collection {
    name     = "AllowInfrastructure"
    priority = 100
    action   = "Allow"

    # DNS（Firewall DNS Proxy 経由のため必須）
    rule {
      name                  = "AllowDNS"
      protocols             = ["UDP", "TCP"]
      source_addresses      = ["*"]
      destination_addresses = ["*"]
      destination_ports     = ["53"]
    }

    # Windows KMS ライセンス認証 (FQDN)
    rule {
      name              = "Allow_KMSServer1"
      protocols         = ["TCP"]
      source_addresses  = ["*"]
      destination_fqdns = ["azkms.core.windows.net", "kms.core.windows.net"]
      destination_ports = ["1688"]
    }

    # Windows KMS ライセンス認証 (IP)
    rule {
      name                  = "Allow_KMSServer2"
      protocols             = ["TCP"]
      source_addresses      = ["*"]
      destination_addresses = ["20.118.99.224", "40.83.235.53"]
      destination_ports     = ["1688"]
    }

    # Azure Machine Configuration (Guest Configuration / Arc)
    rule {
      name                  = "Allow_Machine-Configuration"
      protocols             = ["TCP"]
      source_addresses      = ["*"]
      destination_addresses = ["AzureArcInfrastructure", "Storage"]
      destination_ports     = ["80", "443"]
    }

    # Azure Monitor Agent
    rule {
      name                  = "Allow_AzureMonitorAgent"
      protocols             = ["TCP"]
      source_addresses      = ["*"]
      destination_addresses = ["AzureMonitor", "AzureResourceManager"]
      destination_ports     = ["443"]
    }

    # RHEL RHUI パッチ配信
    rule {
      name                  = "Allow_RHUI"
      protocols             = ["TCP"]
      source_addresses      = ["*"]
      destination_addresses = ["52.136.197.163", "20.225.226.182", "52.142.4.99", "20.248.180.252", "20.24.186.80"]
      destination_ports     = ["443"]
    }

    # Azure Portal / Entra ID / ARM / Front Door
    rule {
      name                  = "Allow_AzurePortal"
      protocols             = ["TCP", "UDP", "ICMP", "Any"]
      source_addresses      = ["*"]
      destination_addresses = ["AzurePortal", "AzureActiveDirectory", "AzureResourceManager", "AzureFrontDoor.Frontend"]
      destination_ports     = ["*"]
    }
  }

  network_rule_collection {
    name     = "AllowM365andAKS"
    priority = 110
    action   = "Allow"

    # Microsoft 365 (ネットワーク層)
    rule {
      name             = "Allow_M365"
      protocols        = ["TCP", "UDP", "ICMP"]
      source_addresses = ["*"]
      destination_addresses = [
        "Office365.Exchange.Optimize",
        "Office365.Exchange.Allow.Required",
        "Office365.Exchange.Allow.NotRequired",
        "Office365.Skype.Optimize",
        "Office365.Skype.Allow.Required",
        "Office365.Skype.Allow.NotRequired",
        "Office365.SharePoint.Optimize",
        "Office365.Common.Allow.Required",
      ]
      destination_ports = ["*"]
    }

    # AKS — API Server / Tunnel (TCP 9000)
    rule {
      name                  = "Allow_AKS1"
      protocols             = ["TCP"]
      source_addresses      = ["*"]
      destination_addresses = ["AzureCloud.${each.value.location}"]
      destination_ports     = ["9000"]
    }

    # AKS — NTP + Tunnel (UDP 123, 1194)
    rule {
      name                  = "Allow_AKS2"
      protocols             = ["UDP"]
      source_addresses      = ["*"]
      destination_addresses = ["AzureCloud.${each.value.location}"]
      destination_ports     = ["123", "1194"]
    }
  }

  # ===== アプリケーションルール =====

  application_rule_collection {
    name     = "AllowPlatformServices"
    priority = 200
    action   = "Allow"

    # Defender for Containers / Log Analytics
    rule {
      name             = "Allow_DefenderForContainers"
      source_addresses = ["*"]
      protocols {
        type = "Https"
        port = 443
      }
      destination_fqdns = [
        "login.microsoftonline.com",
        "*.ods.opinsights.azure.com",
        "*.oms.opinsights.azure.com",
        "*.cloud.defender.microsoft.com",
      ]
    }

    # Office365 証明書チェーン (Amazon Trust)
    rule {
      name             = "Allow_Office365_CertChain"
      source_addresses = ["*"]
      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
      destination_fqdns = ["*.amazontrust.com"]
    }

    # Ubuntu パッケージ更新
    rule {
      name             = "Allow_Ubuntu"
      source_addresses = ["*"]
      protocols {
        type = "Https"
        port = 443
      }
      destination_fqdns = [
        "security.ubuntu.com",
        "archive.ubuntu.com",
        "azure.archive.ubuntu.com",
        "motd.ubuntu.com",
        "*.archive.ubuntu.com",
        "entropy.ubuntu.com",
        "api.snapcraft.io",
        "changelogs.ubuntu.com",
      ]
    }
  }

  application_rule_collection {
    name     = "AllowCloudServices"
    priority = 210
    action   = "Allow"

    # Windows Update (FQDN Tag)
    rule {
      name             = "Allow_WindowsUpdate"
      source_addresses = ["*"]
      protocols {
        type = "Https"
        port = 443
      }
      destination_fqdn_tags = ["WindowsUpdate"]
    }

    # AKS (FQDN Tag)
    rule {
      name             = "Allow_AKS"
      source_addresses = ["*"]
      protocols {
        type = "Https"
        port = 443
      }
      destination_fqdn_tags = ["AzureKubernetesService"]
    }
  }
}

# =============================================================================
# Spoke Network Rules — サブスクリプション YAML から自動生成
# =============================================================================

resource "azurerm_firewall_policy_rule_collection_group" "spoke_network" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v
    if v.firewall_subnet_prefix != null && length(local.vending_with_firewall_rules) > 0
  }
  provider           = azurerm.connectivity
  name               = "SpokeNetworkRules"
  firewall_policy_id = azurerm_firewall_policy.hub[each.key].id
  priority           = 1000

  dynamic "network_rule_collection" {
    for_each = {
      for sub_key, fw in local.vending_with_firewall_rules : sub_key => fw
      if length(fw.network_rules) > 0
    }
    content {
      name = "${network_rule_collection.key}-network"
      priority = 100 + index(keys({
        for sk, fw in local.vending_with_firewall_rules : sk => fw if length(fw.network_rules) > 0
      }), network_rule_collection.key)
      action = "Allow"

      dynamic "rule" {
        for_each = network_rule_collection.value.network_rules
        content {
          name                  = rule.value.name
          protocols             = rule.value.protocols
          source_addresses      = rule.value.source_addresses
          destination_addresses = try(rule.value.destination_addresses, null)
          destination_fqdns     = try(rule.value.destination_fqdns, null)
          destination_ports     = rule.value.destination_ports
        }
      }
    }
  }
}

# =============================================================================
# Spoke Application Rules — サブスクリプション YAML から自動生成
# =============================================================================

resource "azurerm_firewall_policy_rule_collection_group" "spoke_application" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v
    if v.firewall_subnet_prefix != null && length(local.vending_with_firewall_rules) > 0
  }
  provider           = azurerm.connectivity
  name               = "SpokeApplicationRules"
  firewall_policy_id = azurerm_firewall_policy.hub[each.key].id
  priority           = 2000

  dynamic "application_rule_collection" {
    for_each = {
      for sub_key, fw in local.vending_with_firewall_rules : sub_key => fw
      if length(fw.application_rules) > 0
    }
    content {
      name = "${application_rule_collection.key}-application"
      priority = 100 + index(keys({
        for sk, fw in local.vending_with_firewall_rules : sk => fw if length(fw.application_rules) > 0
      }), application_rule_collection.key)
      action = "Allow"

      dynamic "rule" {
        for_each = application_rule_collection.value.application_rules
        content {
          name              = rule.value.name
          source_addresses  = rule.value.source_addresses
          destination_fqdns = try(rule.value.destination_fqdns, null)
          destination_urls  = try(rule.value.destination_urls, null)

          dynamic "protocols" {
            for_each = rule.value.protocols
            content {
              type = protocols.value.type
              port = protocols.value.port
            }
          }
        }
      }
    }
  }
}

# =============================================================================
# Azure Firewall
# =============================================================================

resource "azurerm_public_ip" "firewall" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.firewall_subnet_prefix != null
  }
  provider            = azurerm.connectivity
  name                = "pip-fw-hub-${each.value.location}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall" "hub" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.firewall_subnet_prefix != null
  }
  provider            = azurerm.connectivity
  name                = "fw-hub-${each.value.location}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name
  sku_name            = "AZFW_VNet"
  sku_tier            = each.value.firewall_sku_tier
  firewall_policy_id  = azurerm_firewall_policy.hub[each.key].id

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.firewall[each.key].id
    public_ip_address_id = azurerm_public_ip.firewall[each.key].id
  }

  tags = var.tags
}

# =============================================================================
# Azure Bastion
# =============================================================================

resource "azurerm_public_ip" "bastion" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.bastion_subnet_prefix != null
  }
  provider            = azurerm.connectivity
  name                = "pip-bastion-${each.value.location}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "hub" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.bastion_subnet_prefix != null
  }
  provider            = azurerm.connectivity
  name                = "bastion-hub-${each.value.location}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = azurerm_subnet.bastion[each.key].id
    public_ip_address_id = azurerm_public_ip.bastion[each.key].id
  }

  tags = var.tags

  # DNS Resolver の VNet 操作完了後に作成。
  # Bastion と DNS Resolver は同一 VNet を操作するため、同時実行すると
  # VNet の provisioningState が Updating のまま BadRequest になる。
  # DNS Resolver（数十秒）→ Bastion（約 10 分）の順で直列化する。
  depends_on = [
    azurerm_virtual_network_gateway.er,
    azurerm_private_dns_resolver_outbound_endpoint.hub,
  ]
}

# =============================================================================
# Private DNS Resolver
# =============================================================================

resource "azurerm_private_dns_resolver" "hub" {
  for_each = {
    for k, v in var.hub_virtual_networks :
    k => v if v.dns_resolver_inbound_subnet_prefix != null && v.dns_resolver_outbound_subnet_prefix != null
  }
  provider            = azurerm.connectivity
  name                = "pdr-hub-${each.value.location}"
  resource_group_name = azurerm_resource_group.hub[each.key].name
  location            = each.value.location
  virtual_network_id  = azurerm_virtual_network.hub[each.key].id

  tags = var.tags

  # ER Gateway の VNet ロック解放後に作成
  depends_on = [azurerm_virtual_network_gateway.er]
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "hub" {
  for_each = {
    for k, v in var.hub_virtual_networks :
    k => v if v.dns_resolver_inbound_subnet_prefix != null
  }
  provider                = azurerm.connectivity
  name                    = "pdr-inbound-${each.value.location}"
  location                = each.value.location
  private_dns_resolver_id = azurerm_private_dns_resolver.hub[each.key].id
  ip_configurations {
    private_ip_allocation_method = "Dynamic"
    subnet_id                    = azurerm_subnet.dns_resolver_inbound[each.key].id
  }

  tags = var.tags
}

resource "azurerm_private_dns_resolver_outbound_endpoint" "hub" {
  for_each = {
    for k, v in var.hub_virtual_networks :
    k => v if v.dns_resolver_outbound_subnet_prefix != null
  }
  provider                = azurerm.connectivity
  name                    = "pdr-outbound-${each.value.location}"
  location                = each.value.location
  private_dns_resolver_id = azurerm_private_dns_resolver.hub[each.key].id
  subnet_id               = azurerm_subnet.dns_resolver_outbound[each.key].id

  tags = var.tags
}

resource "azurerm_private_dns_resolver_dns_forwarding_ruleset" "hub" {
  for_each = {
    for k, v in var.hub_virtual_networks :
    k => v if v.dns_resolver_outbound_subnet_prefix != null
  }
  provider            = azurerm.connectivity
  name                = "pdr-ruleset-${each.value.location}"
  resource_group_name = azurerm_resource_group.hub[each.key].name
  location            = each.value.location

  private_dns_resolver_outbound_endpoint_ids = [azurerm_private_dns_resolver_outbound_endpoint.hub[each.key].id]

  tags = var.tags
}

# =============================================================================
# ExpressRoute Circuit
# =============================================================================

resource "azurerm_express_route_circuit" "hub" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.gateway_subnet_prefix != null
  }
  provider            = azurerm.connectivity
  name                = "erc-hub-${each.value.location}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name

  service_provider_name = each.value.express_route.service_provider_name
  peering_location      = each.value.express_route.peering_location
  bandwidth_in_mbps     = each.value.express_route.bandwidth_in_mbps

  sku {
    tier   = each.value.express_route.sku_tier
    family = each.value.express_route.sku_family
  }

  tags = var.tags
}

# =============================================================================
# ExpressRoute Gateway
# =============================================================================

resource "azurerm_virtual_network_gateway" "er" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.gateway_subnet_prefix != null
  }
  provider            = azurerm.connectivity
  name                = "ergw-hub-${each.value.location}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name
  type                = "ExpressRoute"
  sku                 = each.value.gateway_sku

  ip_configuration {
    name                          = "ergw-ipconfig"
    subnet_id                     = azurerm_subnet.gateway[each.key].id
    private_ip_address_allocation = "Dynamic"
  }

  tags = var.tags

  # ER Gateway は VNet ロックを 30-45 分保持する。
  # 全サブネット作成完了後に開始し、他サブネットのリトライを防ぐ。
  depends_on = [
    azurerm_subnet.bastion,
    azurerm_subnet.firewall,
    azurerm_subnet.firewall_management,
    azurerm_subnet.dns_resolver_inbound,
    azurerm_subnet.dns_resolver_outbound,
  ]
}

# =============================================================================
# ExpressRoute Connection（キャリア開通後に connection_enabled = true で有効化）
# =============================================================================

resource "azurerm_virtual_network_gateway_connection" "er" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v
    if v.gateway_subnet_prefix != null && try(v.express_route.connection_enabled, false)
  }
  provider            = azurerm.connectivity
  name                = "cn-er-hub-${each.value.location}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name
  type                = "ExpressRoute"

  virtual_network_gateway_id = azurerm_virtual_network_gateway.er[each.key].id
  express_route_circuit_id   = azurerm_express_route_circuit.hub[each.key].id

  tags = var.tags
}

# =============================================================================
# Route Tables
# =============================================================================

# Spoke → Firewall のデフォルトルート（BGP 伝搬無効 — オンプレルートを学習させない）
resource "azurerm_route_table" "spoke_to_firewall" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v if v.firewall_subnet_prefix != null
  }
  provider            = azurerm.connectivity
  name                = "rt-spoke-to-fw-${each.value.location}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name

  bgp_route_propagation_enabled = false

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.hub[each.key].ip_configuration[0].private_ip_address
  }

  tags = var.tags
}

# GatewaySubnet ルートテーブル — Spoke VNet 行きを Firewall 経由にする
resource "azurerm_route_table" "gateway" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v
    if v.gateway_subnet_prefix != null && v.firewall_subnet_prefix != null
  }
  provider            = azurerm.connectivity
  name                = "rt-gateway-${each.value.location}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.hub[each.key].name

  # BGP 伝搬は有効（ER から学習したオンプレルートが必要）
  bgp_route_propagation_enabled = true

  tags = var.tags
}

resource "azurerm_subnet_route_table_association" "gateway" {
  for_each = {
    for k, v in var.hub_virtual_networks : k => v
    if v.gateway_subnet_prefix != null && v.firewall_subnet_prefix != null
  }
  provider       = azurerm.connectivity
  subnet_id      = azurerm_subnet.gateway[each.key].id
  route_table_id = azurerm_route_table.gateway[each.key].id

  # policy_exemptions: destroy 時に免除が先に削除されると Network GR の
  # deny-subnet-without-udr が UDR 解除をブロックするため、
  # destroy 順序を route_table_association → exemptions に強制する
  depends_on = [azurerm_virtual_network_gateway.er, azapi_resource.policy_exemptions]
}

# GatewaySubnet ルート: var.spoke_virtual_networks の各 Spoke VNet → Firewall
resource "azurerm_route" "gateway_to_spoke" {
  for_each = {
    for item in flatten([
      for hub_key, hub in var.hub_virtual_networks : [
        for spoke_key, spoke in var.spoke_virtual_networks : [
          for i, cidr in spoke.address_space : {
            key            = "${hub_key}-${spoke_key}-${i}"
            hub_key        = hub_key
            name           = "to-${spoke_key}-${i}"
            address_prefix = cidr
          }
        ] if spoke.hub_key == hub_key
      ] if hub.gateway_subnet_prefix != null && hub.firewall_subnet_prefix != null
    ]) : item.key => item
  }
  provider               = azurerm.connectivity
  name                   = each.value.name
  resource_group_name    = azurerm_resource_group.hub[each.value.hub_key].name
  route_table_name       = azurerm_route_table.gateway[each.value.hub_key].name
  address_prefix         = each.value.address_prefix
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.hub[each.value.hub_key].ip_configuration[0].private_ip_address
}

# =============================================================================
# Hub-to-Hub VNet Peering（複数 Hub がある場合の相互接続）
# =============================================================================

resource "azurerm_virtual_network_peering" "hub_forward" {
  for_each                     = local.hub_peering_pairs
  provider                     = azurerm.connectivity
  name                         = "peer-${each.value.from}-to-${each.value.to}"
  resource_group_name          = azurerm_resource_group.hub[each.value.from].name
  virtual_network_name         = azurerm_virtual_network.hub[each.value.from].name
  remote_virtual_network_id    = azurerm_virtual_network.hub[each.value.to].id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "hub_reverse" {
  for_each                     = local.hub_peering_pairs
  provider                     = azurerm.connectivity
  name                         = "peer-${each.value.to}-to-${each.value.from}"
  resource_group_name          = azurerm_resource_group.hub[each.value.to].name
  virtual_network_name         = azurerm_virtual_network.hub[each.value.to].name
  remote_virtual_network_id    = azurerm_virtual_network.hub[each.value.from].id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

# =============================================================================
# Spoke Virtual Networks
# =============================================================================

resource "azurerm_virtual_network" "spoke" {
  for_each            = var.spoke_virtual_networks
  provider            = azurerm.connectivity
  name                = "vnet-${each.key}"
  location            = each.value.location
  resource_group_name = each.value.resource_group_name
  address_space       = each.value.address_space
  tags                = var.tags

  depends_on = [azurerm_resource_group.hub]
}

# Spoke Subnets
resource "azurerm_subnet" "spoke" {
  for_each = {
    for item in flatten([
      for vnet_key, vnet in var.spoke_virtual_networks : [
        for subnet_key, subnet in vnet.subnets : {
          key                 = "${vnet_key}-${subnet_key}"
          vnet_key            = vnet_key
          subnet_name         = subnet_key
          address_prefix      = subnet.address_prefix
          resource_group_name = vnet.resource_group_name
        }
      ]
    ]) : item.key => item
  }
  provider             = azurerm.connectivity
  name                 = each.value.subnet_name
  resource_group_name  = each.value.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke[each.value.vnet_key].name
  address_prefixes     = [each.value.address_prefix]
}

# Spoke NSG（サブネットごとに 1 つ）
resource "azurerm_network_security_group" "spoke" {
  for_each = {
    for item in flatten([
      for vnet_key, vnet in var.spoke_virtual_networks : [
        for subnet_key, subnet in vnet.subnets : {
          key                 = "${vnet_key}-${subnet_key}"
          vnet_key            = vnet_key
          subnet_name         = subnet_key
          location            = vnet.location
          resource_group_name = vnet.resource_group_name
        }
      ]
    ]) : item.key => item
  }
  provider            = azurerm.connectivity
  name                = "nsg-${each.value.subnet_name}"
  location            = each.value.location
  resource_group_name = each.value.resource_group_name
  tags                = var.tags
}

# NSG → Subnet Association
resource "azurerm_subnet_network_security_group_association" "spoke" {
  for_each = {
    for item in flatten([
      for vnet_key, vnet in var.spoke_virtual_networks : [
        for subnet_key, subnet in vnet.subnets : {
          key = "${vnet_key}-${subnet_key}"
        }
      ]
    ]) : item.key => item
  }
  provider                  = azurerm.connectivity
  subnet_id                 = azurerm_subnet.spoke[each.key].id
  network_security_group_id = azurerm_network_security_group.spoke[each.key].id
}

# Spoke UDR → Subnet Association（Firewall がある Hub に接続する Spoke のみ）
resource "azurerm_subnet_route_table_association" "spoke" {
  for_each = {
    for item in flatten([
      for vnet_key, vnet in var.spoke_virtual_networks : [
        for subnet_key, subnet in vnet.subnets : {
          key     = "${vnet_key}-${subnet_key}"
          hub_key = vnet.hub_key
        }
      ] if contains(keys(azurerm_firewall.hub), vnet.hub_key)
    ]) : item.key => item
  }
  provider       = azurerm.connectivity
  subnet_id      = azurerm_subnet.spoke[each.key].id
  route_table_id = azurerm_route_table.spoke_to_firewall[each.value.hub_key].id
}

# =============================================================================
# Hub-Spoke VNet Peering
# =============================================================================

# Spoke → Hub
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  for_each                     = var.spoke_virtual_networks
  provider                     = azurerm.connectivity
  name                         = "peer-${each.key}-to-hub"
  resource_group_name          = each.value.resource_group_name
  virtual_network_name         = azurerm_virtual_network.spoke[each.key].name
  remote_virtual_network_id    = azurerm_virtual_network.hub[each.value.hub_key].id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
  use_remote_gateways          = false
}

# Hub → Spoke
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each                     = var.spoke_virtual_networks
  provider                     = azurerm.connectivity
  name                         = "peer-hub-to-${each.key}"
  resource_group_name          = azurerm_resource_group.hub[each.value.hub_key].name
  virtual_network_name         = azurerm_virtual_network.hub[each.value.hub_key].name
  remote_virtual_network_id    = azurerm_virtual_network.spoke[each.key].id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
  allow_gateway_transit        = false
}
