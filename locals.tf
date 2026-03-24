locals {
  # Hub VNet のキー一覧
  hub_keys = keys(var.hub_virtual_networks)

  # Hub-to-Hub ピアリングの組み合わせ（2 つ以上の Hub がある場合）
  hub_peering_pairs = {
    for pair in flatten([
      for i, from_key in local.hub_keys : [
        for j, to_key in local.hub_keys : {
          from = from_key
          to   = to_key
        } if i < j
      ]
    ]) : "${pair.from}-to-${pair.to}" => pair
  }

  # Private DNS Zone × Hub VNet の組み合わせ（VNet リンク用）
  dns_zone_vnet_links = var.private_dns_enabled ? {
    for pair in setproduct(tolist(var.private_dns_zones), local.hub_keys) :
    "${replace(pair[0], ".", "-")}-${pair[1]}" => {
      zone_name = pair[0]
      hub_key   = pair[1]
    }
  } : {}

  # DNS アウトバウンド転送ルール — dns-forwarding-rules.yaml × 全 Hub の直積
  # 全 Hub の forwarding ruleset に同一ルールを作成し、DR 切替時も名前解決を継続する。
  _dns_forwarding_rules_raw = try(yamldecode(file("${path.module}/dns-forwarding-rules.yaml")), [])

  dns_forwarding_rules = {
    for entry in flatten([
      for rule in local._dns_forwarding_rules_raw : [
        for hub_key, hub in var.hub_virtual_networks : {
          key                = "${hub_key}/${rule.name}"
          hub_key            = hub_key
          name               = rule.name
          domain_name        = rule.domain_name
          target_dns_servers = rule.target_dns_servers
          enabled            = try(rule.enabled, true)
        }
        if hub.dns_resolver_outbound_subnet_prefix != null
      ]
    ]) : entry.key => entry
  }
}
