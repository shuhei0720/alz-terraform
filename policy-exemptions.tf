# =============================================================================
# ポリシー免除（Policy Exemptions）
# =============================================================================
#
# ガードレール強制化に伴い、特定リソースに対するポリシー免除を
# 宣言的に管理する。免除の定義場所は 2 箇所:
#
# 1. lib/policy_exemptions/*.yaml — グローバル免除（MG・基盤リソース向け）
#    management_group_suffix を明示的に指定する。
#
# 2. subscriptions/<name>.yaml の policy_exemptions セクション — サブスクリプション免除
#    scope 内の ${subscription_id} が自動解決される。
#    management_group_suffix は YAML の management_group_id から自動推定。
#
# azapi_resource を使用しているため:
#   - 任意のサブスクリプション（基盤・Spoke 問わず）に適用可能
#   - MG / サブスクリプション / RG / リソース の全スコープレベルに対応
#
# サブスクリプション YAML の policy_exemptions フォーマット:
#   policy_exemptions:
#     - name: <一意の免除名>
#       policy_assignment: <ポリシー割り当て名>
#       scope: <免除スコープ — ${subscription_id} でサブスク ID に自動変換>
#       category: Waiver | Mitigated
#       display_name: <表示名>
#       description: <理由>
#       policy_definition_reference_ids: [省略可]
#       management_group_suffix: [省略可] 省略時は所属 MG から自動推定
#
# =============================================================================

locals {
  # 変数参照の解決マップ（YAML 内の ${var_name} → 実際の値）
  #
  # for_each の安定性: 全ての値は計画時に確定する必要がある。
  # リソース属性 (*.id) に依存すると新規デプロイ時に unknown になり
  # for_each のキーセットが確定できない。変数と命名規則から
  # 決定論的に ID を構築する。
  _law_archive_sa_enabled = var.law_archive_retention_days > 0
  _law_archive_sa_id = (
    local._law_archive_sa_enabled
    ? "/subscriptions/${var.subscription_ids["management"]}/resourceGroups/rg-management-${var.primary_location}/providers/Microsoft.Storage/storageAccounts/stlawarchive${replace(var.primary_location, " ", "")}"
    : ""
  )

  exemption_scope_vars = {
    terraform_state_storage_account_id = var.terraform_state_storage_account_id
    terraform_state_rg_id = (
      var.terraform_state_storage_account_id != ""
      ? join("/", slice(split("/", var.terraform_state_storage_account_id), 0, 5))
      : ""
    )
    law_archive_sa_id            = local._law_archive_sa_id
    root_management_group_id     = "/providers/Microsoft.Management/managementGroups/${var.root_id}"
    management_subscription_id   = "/subscriptions/${var.subscription_ids["management"]}"
    connectivity_subscription_id = "/subscriptions/${var.subscription_ids["connectivity"]}"
    identity_subscription_id     = "/subscriptions/${var.subscription_ids["identity"]}"
    security_subscription_id     = "/subscriptions/${var.subscription_ids["security"]}"
  }

  # --- MG サフィックスの自動推定マップ ---
  # サブスクリプションの management_group_id → ガードレールが割り当てられている MG
  _mg_to_guardrail_mg = {
    corp         = "landingzones"
    online       = "landingzones"
    management   = "platform"
    connectivity = "platform"
    identity     = "platform"
    security     = "platform"
  }

  # --- 1. グローバル免除（lib/policy_exemptions/*.yaml） ---
  _raw_exemptions = flatten([
    for f in fileset("${path.module}/lib/policy_exemptions", "*.yaml") :
    yamldecode(file("${path.module}/lib/policy_exemptions/${f}")).exemptions
  ])

  # scope 内の ${var_name} を実際の値に解決し、空スコープはスキップ
  _global_exemptions = {
    for e in local._raw_exemptions :
    e.name => merge(e, {
      resolved_scope = try(
        local.exemption_scope_vars[trimprefix(trimsuffix(e.scope, "}"), "$${")],
        e.scope
      )
    })
    if try(
      local.exemption_scope_vars[trimprefix(trimsuffix(e.scope, "}"), "$${")],
      e.scope
    ) != ""
  }

  # --- 2. サブスクリプション免除（subscriptions/*.yaml の policy_exemptions） ---
  _subscription_exemptions_list = flatten([
    for sub_key, sub in local.subscriptions : [
      for e in try(sub.policy_exemptions, []) : merge(e, {
        _sub_key = sub_key
        _sub_id  = local.resolved_subscription_ids[sub_key]
        _mg_id   = try(sub.management_group_id, "")
      })
    ]
  ])

  _subscription_exemptions = {
    for e in local._subscription_exemptions_list :
    e.name => {
      name                            = e.name
      policy_assignment               = e.policy_assignment
      category                        = e.category
      display_name                    = e.display_name
      description                     = try(e.description, null)
      policy_definition_reference_ids = try(e.policy_definition_reference_ids, null)
      management_group_suffix = try(
        e.management_group_suffix,
        lookup(local._mg_to_guardrail_mg, e._mg_id, e._mg_id)
      )
      resolved_scope = replace(e.scope, "$${subscription_id}", e._sub_id)
    }
    if replace(e.scope, "$${subscription_id}", e._sub_id) != ""
  }

  # --- 3. インフラ構成に基づく動的免除 ---
  # Hub VNet のみ HCL で管理（for_each が動的なため YAML では不可）
  # その他は全て YAML に移行済み
  _infrastructure_exemptions = merge(
    # Hub VNet: Network ガードレール免除（特殊サブネット）
    {
      for hub_key in keys(var.hub_virtual_networks) :
      "exempt-hub-${hub_key}-network-gr" => {
        name                            = "exempt-hub-${hub_key}-network-gr"
        policy_assignment               = "Enforce-GR-Network0"
        management_group_suffix         = "platform"
        resolved_scope                  = azurerm_virtual_network.hub[hub_key].id
        category                        = "Waiver"
        display_name                    = "Hub VNet (${hub_key}) — Network GR 免除"
        description                     = "Hub の特殊サブネット(Firewall/Bastion/Gateway/DNS Resolver)は設計上 NSG/UDR を付与できないため免除"
        policy_definition_reference_ids = ["deny-subnet-without-nsg", "deny-subnet-without-udr"]
      }
    },
    # Hub VNet: Subnet Private (defaultOutboundAccess) 免除
    {
      for hub_key in keys(var.hub_virtual_networks) :
      "exempt-hub-${hub_key}-subnet-private" => {
        name                            = "exempt-hub-${hub_key}-subnet-private"
        policy_assignment               = "Enforce-Subnet-Private"
        management_group_suffix         = "platform"
        resolved_scope                  = azurerm_virtual_network.hub[hub_key].id
        category                        = "Waiver"
        display_name                    = "Hub VNet (${hub_key}) — Subnet Private 免除"
        description                     = "Hub 特殊サブネットは専用のアウトバウンド経路を持つため defaultOutboundAccess 設定不要"
        policy_definition_reference_ids = null
      }
    },
    # Hub Firewall: Zone Resiliency 免除
    {
      for hub_key, hub in var.hub_virtual_networks :
      "exempt-hub-${hub_key}-fw-zone" => {
        name                            = "exempt-hub-${hub_key}-fw-zone"
        policy_assignment               = "Audit-ZoneResiliency"
        management_group_suffix         = ""
        resolved_scope                  = azurerm_firewall.hub[hub_key].id
        category                        = "Waiver"
        display_name                    = "Hub Firewall (${hub_key}) — Zone Resiliency 免除"
        description                     = "Azure Firewall の zones プロパティは廃止予定。ゾーン冗長は Azure 側で自動適用されるため免除"
        policy_definition_reference_ids = null
      } if hub.firewall_subnet_prefix != null
    },
    # Hub Firewall PIP: Zone Resiliency 免除
    {
      for hub_key, hub in var.hub_virtual_networks :
      "exempt-hub-${hub_key}-fw-pip-zone" => {
        name                            = "exempt-hub-${hub_key}-fw-pip-zone"
        policy_assignment               = "Audit-ZoneResiliency"
        management_group_suffix         = ""
        resolved_scope                  = azurerm_public_ip.firewall[hub_key].id
        category                        = "Waiver"
        display_name                    = "Hub Firewall PIP (${hub_key}) — Zone Resiliency 免除"
        description                     = "Public IP の zones プロパティは廃止予定。ゾーン冗長は Azure 側で自動適用されるため免除"
        policy_definition_reference_ids = null
      } if hub.firewall_subnet_prefix != null
    },
    # Hub Bastion PIP: Zone Resiliency 免除
    {
      for hub_key, hub in var.hub_virtual_networks :
      "exempt-hub-${hub_key}-bastion-pip-zone" => {
        name                            = "exempt-hub-${hub_key}-bastion-pip-zone"
        policy_assignment               = "Audit-ZoneResiliency"
        management_group_suffix         = ""
        resolved_scope                  = azurerm_public_ip.bastion[hub_key].id
        category                        = "Waiver"
        display_name                    = "Hub Bastion PIP (${hub_key}) — Zone Resiliency 免除"
        description                     = "Public IP の zones プロパティは廃止予定。ゾーン冗長は Azure 側で自動適用されるため免除"
        policy_definition_reference_ids = null
      } if hub.bastion_subnet_prefix != null
    },
    # Bastion 録画 SA: Storage ガードレール免除
    {
      for hub_key, hub in var.hub_virtual_networks :
      "exempt-hub-${hub_key}-bastion-rec-sa-storage-gr" => {
        name                            = "exempt-hub-${hub_key}-bastion-rec-sa-storage-gr"
        policy_assignment               = "Enforce-GR-Storage0"
        management_group_suffix         = "platform"
        resolved_scope                  = azurerm_storage_account.bastion_recording[hub_key].id
        category                        = "Waiver"
        display_name                    = "Bastion Recording SA (${hub_key}) — Storage GR 免除"
        description                     = "Bastion セッション録画専用 SA。MI 認証でアクセス。SharedKey 制限等は個別設定済み。"
        policy_definition_reference_ids = null
      } if hub.bastion_subnet_prefix != null && hub.bastion_sku == "Premium"
    },
    # Bastion 録画 SA: CMK 免除
    {
      for hub_key, hub in var.hub_virtual_networks :
      "exempt-hub-${hub_key}-bastion-rec-sa-cmk" => {
        name                            = "exempt-hub-${hub_key}-bastion-rec-sa-cmk"
        policy_assignment               = "Enforce-Encrypt-CMK0"
        management_group_suffix         = "platform"
        resolved_scope                  = azurerm_storage_account.bastion_recording[hub_key].id
        category                        = "Waiver"
        display_name                    = "Bastion Recording SA (${hub_key}) — CMK 免除"
        description                     = "Microsoft-managed keys で運用。CMK はコスト・運用複雑性のトレードオフにより見送り。"
        policy_definition_reference_ids = null
      } if hub.bastion_subnet_prefix != null && hub.bastion_sku == "Premium"
    },
    # Bastion 録画 SA: MCSB 免除
    {
      for hub_key, hub in var.hub_virtual_networks :
      "exempt-hub-${hub_key}-bastion-rec-sa-mcsb" => {
        name                            = "exempt-hub-${hub_key}-bastion-rec-sa-mcsb"
        policy_assignment               = "Deploy-MCSB2-Monitoring"
        management_group_suffix         = ""
        resolved_scope                  = azurerm_storage_account.bastion_recording[hub_key].id
        category                        = "Waiver"
        display_name                    = "Bastion Recording SA (${hub_key}) — MCSB 免除"
        description                     = "録画専用 SA は CMK 未使用・PrivateEndpoint 未構成など MCSB ストレージポリシーに構造的に準拠できないため免除。"
        policy_definition_reference_ids = null
      } if hub.bastion_subnet_prefix != null && hub.bastion_sku == "Premium"
    },
    # Bastion 録画 SA: ASC 免除
    {
      for hub_key, hub in var.hub_virtual_networks :
      "exempt-hub-${hub_key}-bastion-rec-sa-asc" => {
        name                            = "exempt-hub-${hub_key}-bastion-rec-sa-asc"
        policy_assignment               = "Deploy-ASC-Monitoring"
        management_group_suffix         = ""
        resolved_scope                  = azurerm_storage_account.bastion_recording[hub_key].id
        category                        = "Waiver"
        display_name                    = "Bastion Recording SA (${hub_key}) — ASC 免除"
        description                     = "Deploy-MCSB2-Monitoring と重複する ASC ストレージポリシーについても同様にリソーススコープで免除。"
        policy_definition_reference_ids = null
      } if hub.bastion_subnet_prefix != null && hub.bastion_sku == "Premium"
    },
    # Bastion 録画 SA: Zone Resiliency 免除
    {
      for hub_key, hub in var.hub_virtual_networks :
      "exempt-hub-${hub_key}-bastion-rec-sa-zone" => {
        name                            = "exempt-hub-${hub_key}-bastion-rec-sa-zone"
        policy_assignment               = "Audit-ZoneResiliency"
        management_group_suffix         = ""
        resolved_scope                  = azurerm_storage_account.bastion_recording[hub_key].id
        category                        = "Waiver"
        display_name                    = "Bastion Recording SA (${hub_key}) — Zone Resiliency 免除"
        description                     = "LRS で運用する設計判断。録画データはゾーン冗長不要。"
        policy_definition_reference_ids = null
      } if hub.bastion_subnet_prefix != null && hub.bastion_sku == "Premium"
    },
  )

  # --- 統合: グローバル + サブスクリプション + インフラ動的免除 ---
  policy_exemptions = merge(local._global_exemptions, local._subscription_exemptions, local._infrastructure_exemptions)
}

# ---------------------------------------------------------------------------
# ポリシー免除（全スコープ・全サブスクリプション対応）
# ---------------------------------------------------------------------------
resource "azapi_resource" "policy_exemptions" {
  for_each = local.policy_exemptions

  type      = "Microsoft.Authorization/policyExemptions@2022-07-01-preview"
  name      = each.key
  parent_id = each.value.resolved_scope

  body = {
    properties = {
      policyAssignmentId           = azapi_resource.alz_policy_assignments["${join("-", compact([var.root_id, each.value.management_group_suffix]))}/${each.value.policy_assignment}"].id
      exemptionCategory            = each.value.category
      displayName                  = each.value.display_name
      description                  = try(each.value.description, null)
      policyDefinitionReferenceIds = try(each.value.policy_definition_reference_ids, null)
    }
  }

  response_export_values = []

  # MG 階層伝搬後の一時的な "not at or under" エラーに対応
  retry = {
    error_message_regex  = ["not at or under", "InvalidCreatePolicyExemptionRequest"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }

  depends_on = [
    azapi_resource.alz_policy_assignments,
    # サブスクリプションが MG 配下に配置されてから免除を作成する
    azurerm_management_group_subscription_association.management,
    azurerm_management_group_subscription_association.connectivity,
    azurerm_management_group_subscription_association.identity,
    azurerm_management_group_subscription_association.security,
    azapi_resource.vending_mg_association,
    azapi_resource.vending_mg_association_existing,
    # VNet スコープの免除は VNet 作成後でないと ResourceNotFound になる
    azapi_resource.vending_vnet,
  ]
}


