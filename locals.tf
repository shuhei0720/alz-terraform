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
}
