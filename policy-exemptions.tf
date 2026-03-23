# =============================================================================
# ポリシー免除（Policy Exemptions）
# =============================================================================
#
# ガードレール強制化に伴い、特定リソースに対するポリシー免除を
# lib/policy_exemptions/ の YAML で宣言的に管理する。
#
# azapi_resource を使用しているため:
#   - 任意のサブスクリプション（基盤・Spoke 問わず）に適用可能
#   - MG / サブスクリプション / RG / リソース の全スコープレベルに対応
#
# YAML フォーマット:
#   exemptions:
#     - name: <一意の免除名>
#       policy_assignment: <ポリシー割り当て名>
#       management_group_suffix: <MG サフィックス（root_id-{suffix}）>
#       scope: <免除スコープ — ${変数名} で変数参照可>
#       category: Waiver | Mitigated
#       display_name: <表示名>
#       description: <理由>
#       policy_definition_reference_ids: [省略可] イニシアティブ内の特定ポリシーのみ免除
#
# 免除の追加: lib/policy_exemptions/ に YAML を追加するだけ。
# =============================================================================

locals {
  # 変数参照の解決マップ（YAML 内の ${var_name} → 実際の値）
  exemption_scope_vars = {
    terraform_state_storage_account_id = var.terraform_state_storage_account_id
  }

  # lib/policy_exemptions/*.yaml を全て読み込み、フラットリストに展開
  _raw_exemptions = flatten([
    for f in fileset("${path.module}/lib/policy_exemptions", "*.yaml") :
    yamldecode(file("${path.module}/lib/policy_exemptions/${f}")).exemptions
  ])

  # scope 内の ${var_name} を実際の値に解決し、空スコープはスキップ
  policy_exemptions = {
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

  depends_on = [azapi_resource.alz_policy_assignments]
}
