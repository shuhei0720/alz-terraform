# =============================================================================
# ポリシー免除（Policy Exemptions）
# =============================================================================
#
# ガードレール強制化に伴い、プラットフォーム基盤リソースに対して
# 必要な免除を YAML で定義し、Terraform で展開する。
#
# 免除の追加: exemptions/ に YAML を追加するだけで自動適用される。
# =============================================================================

locals {
  # exemptions/*.yaml を全て読み込み、フラットなリストに展開
  exemption_files = fileset("${path.module}/exemptions", "*.yaml")

  # Terraform state SA の免除（resource_id は変数から注入）
  state_sa_exemptions = var.terraform_state_storage_account_id != "" ? [
    for e in yamldecode(file("${path.module}/exemptions/terraform-state-sa.yaml")).exemptions : {
      key               = "state-sa-${e.policy_assignment}"
      resource_id       = var.terraform_state_storage_account_id
      policy_assignment = e.policy_assignment
      category          = e.category
      display_name      = e.display_name
      description       = e.description
    }
  ] : []

  # 全免除をマップ化（将来の YAML 追加に対応可能）
  policy_exemptions = { for e in local.state_sa_exemptions : e.key => e }
}

# ポリシー免除を展開
# platform MG に割り当てられたポリシーに対する免除
resource "azurerm_resource_policy_exemption" "managed" {
  for_each = local.policy_exemptions

  provider = azurerm.management

  name                 = substr(replace(each.key, "/[^a-zA-Z0-9-]/", "-"), 0, 64)
  resource_id          = each.value.resource_id
  policy_assignment_id = azapi_resource.alz_policy_assignments["${var.root_id}-platform/${each.value.policy_assignment}"].id
  exemption_category   = each.value.category
  display_name         = each.value.display_name
  description          = each.value.description

  depends_on = [azapi_resource.alz_policy_assignments]
}
