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
  exemption_scope_vars = {
    terraform_state_storage_account_id = var.terraform_state_storage_account_id
    terraform_state_rg_id = (
      var.terraform_state_storage_account_id != ""
      ? join("/", slice(split("/", var.terraform_state_storage_account_id), 0, 5))
      : ""
    )
    law_archive_sa_id            = try(azurerm_storage_account.law_archive[0].id, "")
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
    azurerm_management_group_subscription_association.vending,
    azurerm_management_group_subscription_association.vending_existing,
  ]
}

# ---------------------------------------------------------------------------
# SecurityCenterBuiltIn 免除（Azure 自動割り当て — ALZ 管理外）
# ---------------------------------------------------------------------------
#
# Defender for Cloud がサブスクリプション登録時に自動作成する
# SecurityCenterBuiltIn は MG レベルの Deploy-MCSB2-Monitoring /
# Deploy-ASC-Monitoring と完全に重複するため、全サブスクリプションで免除する。
#
# ALZ の alz_policy_assignments には含まれないため、
# policyAssignmentId を直接構築して別リソースで管理する。
# ---------------------------------------------------------------------------

locals {
  _all_subscription_ids = merge(
    var.subscription_ids,
    { for k, v in local.resolved_subscription_ids : k => v if v != "" }
  )
}

resource "azapi_resource" "securitycenter_exemptions" {
  for_each = local._all_subscription_ids

  type      = "Microsoft.Authorization/policyExemptions@2022-07-01-preview"
  name      = "exempt-securitycenterbuiltin-${each.key}"
  parent_id = "/subscriptions/${each.value}"

  body = {
    properties = {
      policyAssignmentId = "/subscriptions/${each.value}/providers/Microsoft.Authorization/policyAssignments/SecurityCenterBuiltIn"
      exemptionCategory  = "Waiver"
      displayName        = "SecurityCenterBuiltIn — MG レベル MCSB と重複"
      description        = "MG レベルの Deploy-MCSB2-Monitoring / Deploy-ASC-Monitoring と完全重複するため免除"
    }
  }

  response_export_values = []

  retry = {
    error_message_regex  = ["not at or under", "InvalidCreatePolicyExemptionRequest", "PolicyAssignmentNotFound"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }

  depends_on = [
    azurerm_management_group_subscription_association.management,
    azurerm_management_group_subscription_association.connectivity,
    azurerm_management_group_subscription_association.identity,
    azurerm_management_group_subscription_association.security,
    azurerm_management_group_subscription_association.vending,
    azurerm_management_group_subscription_association.vending_existing,
  ]
}
