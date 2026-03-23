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
  # YAML では表現できない Terraform リソース ID ベースの免除
  _terraform_state_rg_scope = (
    var.terraform_state_storage_account_id != ""
    ? join("/", slice(split("/", var.terraform_state_storage_account_id), 0, 5))
    : ""
  )

  _infrastructure_exemptions = merge(
    # Hub VNet: Network ガードレール免除（特殊サブネット）
    # AzureFirewallSubnet / GatewaySubnet / AzureBastionSubnet / DNS Resolver は
    # 設計上 NSG/UDR を付与できない or 非推奨
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
    # 特殊サブネットは専用のアウトバウンド経路を持つ (Firewall PIP / Gateway / Bastion PIP)
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
    # LAW Archive SA: Storage ガードレール免除
    # 不変性ポリシー付き専用 SA のため一部設定変更不可
    var.law_archive_retention_days > 0 ? {
      "exempt-law-archive-sa-storage-gr" = {
        name                            = "exempt-law-archive-sa-storage-gr"
        policy_assignment               = "Enforce-GR-Storage0"
        management_group_suffix         = "platform"
        resolved_scope                  = azurerm_storage_account.law_archive[0].id
        category                        = "Waiver"
        display_name                    = "LAW Archive SA — Storage ガードレール免除"
        description                     = "LAW アーカイブは不変性ポリシー付き専用 SA。インフラ暗号化等の作成後変更不可設定があるためガードレール全体を免除"
        policy_definition_reference_ids = null
      }
    } : {},
    # LAW Archive SA: CMK 免除
    var.law_archive_retention_days > 0 ? {
      "exempt-law-archive-sa-cmk" = {
        name                            = "exempt-law-archive-sa-cmk"
        policy_assignment               = "Enforce-Encrypt-CMK0"
        management_group_suffix         = "platform"
        resolved_scope                  = azurerm_storage_account.law_archive[0].id
        category                        = "Waiver"
        display_name                    = "LAW Archive SA — CMK 免除"
        description                     = "CMK はコスト・運用複雑性のトレードオフにより見送り。Microsoft-managed keys で運用"
        policy_definition_reference_ids = null
      }
    } : {},
    # IaC Compliance: ブートストラップリソース免除
    # rg-terraform-state は Terraform 実行の前提条件（鶏と卵問題）で Terraform 管理外
    local._terraform_state_rg_scope != "" ? {
      "exempt-terraform-bootstrap-iac" = {
        name                            = "exempt-terraform-bootstrap-iac"
        policy_assignment               = "Assign-IaC-Compliance"
        management_group_suffix         = "platform"
        resolved_scope                  = local._terraform_state_rg_scope
        category                        = "Waiver"
        display_name                    = "rg-terraform-state — IaC Compliance 免除"
        description                     = "Terraform state backend と GitHub Actions OIDC の UAMI はブートストラップリソース。Terraform 管理外だが正当なインフラ前提リソース"
        policy_definition_reference_ids = null
      }
    } : {},
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
      policyAssignmentId           = azapi_resource.alz_policy_assignments["${var.root_id}-${each.value.management_group_suffix}/${each.value.policy_assignment}"].id
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
