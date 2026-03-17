# =============================================================================
# ポリシーデプロイエンジン
# =============================================================================
#
# alz プロバイダーで ALZ / AMBA / カスタムポリシーライブラリを読み込み、
# azapi で Azure にデプロイします。
#
# - ポリシーの追加・除外は lib/archetype_definitions/ の YAML で管理
# - カスタムポリシーは lib/policy_definitions/ 等の JSON で管理
# - このファイル自体を編集する必要は通常ありません
#
# =============================================================================

# --- プロバイダー設定 ---

provider "alz" {
  library_overwrite_enabled = true
  library_references = [
    {
      path = "platform/alz"
      ref  = "2026.01.2"
    },
    {
      path = "platform/amba"
      ref  = "2026.01.1"
    },
    {
      custom_url = "${path.root}/lib"
    },
  ]
}

provider "azapi" {}

# --- データソース: ライブラリからポリシーを計算 ---

data "alz_architecture" "this" {
  name                     = "alz_with_amba"
  root_management_group_id = var.root_id
  location                 = var.primary_location

  policy_default_values = {
    # =========================================================================
    # ALZ: Log Analytics / AMA / DCR
    # =========================================================================
    log_analytics_workspace_id = jsonencode({
      value = provider::azapi::resource_group_resource_id(
        var.subscription_ids["management"],
        "rg-management-${var.primary_location}",
        "Microsoft.OperationalInsights/workspaces",
        ["law-management-${var.primary_location}"]
      )
    })

    ama_user_assigned_managed_identity_id = jsonencode({
      value = provider::azapi::resource_group_resource_id(
        var.subscription_ids["management"],
        "rg-management-${var.primary_location}",
        "Microsoft.ManagedIdentity/userAssignedIdentities",
        ["uami-ama-${var.primary_location}"]
      )
    })

    ama_user_assigned_managed_identity_name = jsonencode({
      value = "uami-ama-${var.primary_location}"
    })

    ama_vm_insights_data_collection_rule_id = jsonencode({
      value = provider::azapi::resource_group_resource_id(
        var.subscription_ids["management"],
        "rg-management-${var.primary_location}",
        "Microsoft.Insights/dataCollectionRules",
        ["dcr-vm-insights-${var.primary_location}"]
      )
    })

    ama_change_tracking_data_collection_rule_id = jsonencode({
      value = provider::azapi::resource_group_resource_id(
        var.subscription_ids["management"],
        "rg-management-${var.primary_location}",
        "Microsoft.Insights/dataCollectionRules",
        ["dcr-change-tracking-${var.primary_location}"]
      )
    })

    ama_mdfc_sql_data_collection_rule_id = jsonencode({
      value = provider::azapi::resource_group_resource_id(
        var.subscription_ids["management"],
        "rg-management-${var.primary_location}",
        "Microsoft.Insights/dataCollectionRules",
        ["dcr-defender-sql-${var.primary_location}"]
      )
    })

    # =========================================================================
    # ALZ: Private DNS
    # =========================================================================
    private_dns_zone_subscription_id = jsonencode({
      value = var.subscription_ids["connectivity"]
    })

    private_dns_zone_resource_group_name = jsonencode({
      value = "rg-dns-${var.primary_location}"
    })

    private_dns_zone_region = jsonencode({
      value = var.primary_location
    })

    # =========================================================================
    # AMBA: Core settings
    # =========================================================================
    amba_alz_management_subscription_id = jsonencode({
      value = var.subscription_ids["management"]
    })

    amba_alz_resource_group_name = jsonencode({
      value = "rg-amba-alerts-${var.primary_location}"
    })

    amba_alz_resource_group_location = jsonencode({
      value = var.primary_location
    })

    amba_alz_resource_group_tags = jsonencode({
      value = var.tags
    })

    amba_alz_action_group_email = jsonencode({
      value = var.amba_alert_email
    })  # Array type

    amba_alz_user_assigned_managed_identity_name = jsonencode({
      value = "uami-amba-${var.primary_location}"
    })

    # =========================================================================
    # AMBA: Optional (空文字 = 未使用)
    # =========================================================================
    amba_alz_byo_user_assigned_managed_identity_id = jsonencode({ value = "" })
    amba_alz_byo_action_group                      = jsonencode({ value = [] })
    amba_alz_byo_alert_processing_rule             = jsonencode({ value = "" })
    amba_alz_disable_tag_name                      = jsonencode({ value = "MonitorDisable" })
    amba_alz_disable_tag_values                    = jsonencode({ value = ["true", "Test", "Dev", "Sandbox"] })
    amba_alz_arm_role_id                           = jsonencode({ value = [] })
    amba_alz_webhook_service_uri                   = jsonencode({ value = [] })
    amba_alz_event_hub_resource_id                 = jsonencode({ value = [] })
    amba_alz_function_resource_id                  = jsonencode({ value = "" })
    amba_alz_function_trigger_url                  = jsonencode({ value = "" })
    amba_alz_logicapp_resource_id                  = jsonencode({ value = "" })
    amba_alz_logicapp_callback_url                 = jsonencode({ value = "" })
    # Service Health Action Group（通知先を AMBA と同じメールに設定）
    amba_alz_sha_action_group_resources = jsonencode({
      value = {
        actionGroupEmail    = var.amba_alert_email
        eventHubResourceId  = []
        functionResourceId  = ""
        functionTriggerUrl  = ""
        logicappCallbackUrl = ""
        logicappResourceId  = ""
        webhookServiceUri   = []
      }
    })
  }
}

# =============================================================================
# Locals: データソース出力をリソース用のフラットマップに変換
# =============================================================================

locals {
  # Policy Definitions: "mg_id/name" => { key, definition, mg }
  alz_policy_definitions = {
    for pdval in flatten([
      for mg in data.alz_architecture.this.management_groups : [
        for pdname, pd in mg.policy_definitions : {
          key        = pdname
          definition = jsondecode(pd)
          mg         = mg.id
        }
      ]
    ]) : "${pdval.mg}/${pdval.key}" => pdval
  }

  # Policy Set Definitions: "mg_id/name" => { key, set_definition, mg }
  alz_policy_set_definitions = {
    for psdval in flatten([
      for mg in data.alz_architecture.this.management_groups : [
        for psdname, psd in mg.policy_set_definitions : {
          key            = psdname
          set_definition = jsondecode(psd)
          mg             = mg.id
        }
      ]
    ]) : "${psdval.mg}/${psdval.key}" => psdval
  }

  # Policy Assignments: "mg_id/name" => { key, assignment, mg }
  alz_policy_assignments = {
    for paval in flatten([
      for mg in data.alz_architecture.this.management_groups : [
        for paname, pa in mg.policy_assignments : {
          key        = paname
          assignment = jsondecode(pa)
          mg         = mg.id
        }
      ]
    ]) : "${paval.mg}/${paval.key}" => paval
  }

  # Role Definitions: "mg_id/name" => { key, role_definition, mg }
  alz_role_definitions = {
    for rdval in flatten([
      for mg in data.alz_architecture.this.management_groups : [
        for rdname, rd in mg.role_definitions : {
          key             = rdname
          role_definition = jsondecode(rd)
          mg              = mg.id
        }
      ]
    ]) : "${rdval.mg}/${rdval.key}" => rdval
  }

  # Policy Assignment Identities (デプロイ後に取得)
  alz_policy_assignment_identities = {
    for k, v in azapi_resource.alz_policy_assignments :
    k => try(v.identity[0].principal_id, null)
  }

  # 管理対象の Private DNS ゾーン名（role assignment フィルタ用）
  managed_dns_zones = var.private_dns_enabled ? var.private_dns_zones : toset([])

  # Policy Role Assignments (DINE ポリシー用)
  alz_policy_role_assignments = data.alz_architecture.this.policy_role_assignments != null ? {
    for pra in data.alz_architecture.this.policy_role_assignments :
    uuidv5("url", "${pra.policy_assignment_name}${pra.scope}${pra.management_group_id}${pra.role_definition_id}") => {
      principal_id = lookup(
        local.alz_policy_assignment_identities,
        "${pra.management_group_id}/${pra.policy_assignment_name}",
        null
      )
      role_definition_id = (
        startswith(lower(pra.scope), "/subscriptions")
        ? "/subscriptions/${split("/", pra.scope)[2]}${pra.role_definition_id}"
        : pra.role_definition_id
      )
      scope = pra.scope
    } if(
      !strcontains(pra.scope, "00000000-0000-0000-0000-000000000000") &&
      !strcontains(pra.scope, "changeme") &&
      !(
        strcontains(lower(pra.scope), "privatednszones") &&
        !anytrue([for zone in local.managed_dns_zones : strcontains(lower(pra.scope), lower(zone))])
      )
    )
  } : {}
}

# =============================================================================
# デプロイ: ポリシー定義
# =============================================================================

resource "azapi_resource" "alz_policy_definitions" {
  for_each = local.alz_policy_definitions

  type      = "Microsoft.Authorization/policyDefinitions@2023-04-01"
  name      = each.value.definition.name
  parent_id = "/providers/Microsoft.Management/managementGroups/${each.value.mg}"
  body = {
    properties = each.value.definition.properties
  }
  response_export_values = []

  depends_on = [
    azurerm_management_group.root,
    azurerm_management_group.platform,
    azurerm_management_group.landing_zones,
  ]
}

# =============================================================================
# デプロイ: ポリシーセット定義（イニシアティブ）
# =============================================================================

resource "azapi_resource" "alz_policy_set_definitions" {
  for_each = local.alz_policy_set_definitions

  type      = "Microsoft.Authorization/policySetDefinitions@2023-04-01"
  name      = each.value.set_definition.name
  parent_id = "/providers/Microsoft.Management/managementGroups/${each.value.mg}"
  body = {
    properties = each.value.set_definition.properties
  }
  replace_triggers_external_values = lookup(each.value.set_definition.properties, "policyType", null)
  response_export_values           = []

  depends_on = [azapi_resource.alz_policy_definitions]
}

# =============================================================================
# デプロイ: ポリシー割り当て
# =============================================================================

resource "azapi_resource" "alz_policy_assignments" {
  for_each = local.alz_policy_assignments

  type      = "Microsoft.Authorization/policyAssignments@2024-04-01"
  name      = each.value.assignment.name
  parent_id = "/providers/Microsoft.Management/managementGroups/${each.value.mg}"
  location  = var.primary_location
  body = {
    properties = {
      description    = lookup(each.value.assignment.properties, "description", null)
      displayName    = lookup(each.value.assignment.properties, "displayName", null)
      enforcementMode = lookup(each.value.assignment.properties, "enforcementMode", null)
      metadata = merge(
        lookup(each.value.assignment.properties, "metadata", {}),
        { createdBy = "", createdOn = "", updatedBy = "", updatedOn = "" }
      )
      nonComplianceMessages = lookup(each.value.assignment.properties, "nonComplianceMessages", null)
      notScopes             = lookup(each.value.assignment.properties, "notScopes", null)
      overrides             = lookup(each.value.assignment.properties, "overrides", null)
      parameters            = lookup(each.value.assignment.properties, "parameters", null)
      policyDefinitionId    = lookup(each.value.assignment.properties, "policyDefinitionId", null)
      resourceSelectors     = lookup(each.value.assignment.properties, "resourceSelectors", null)
    }
  }
  ignore_missing_property = true
  replace_triggers_external_values = [
    lookup(each.value.assignment.properties, "policyDefinitionId", null),
    var.primary_location,
  ]
  response_export_values = []

  retry = {
    error_message_regex  = ["out of scope", "hierarchy", "not found", "NotFound", "AuthorizationFailed"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }

  dynamic "identity" {
    for_each = lookup(each.value.assignment, "identity", null) != null ? [each.value.assignment.identity] : []
    content {
      type         = identity.value.type
      identity_ids = keys(lookup(identity.value, "userAssignedIdentities", {}))
    }
  }

  lifecycle {
    ignore_changes = [
      body.properties.metadata.createdBy,
      body.properties.metadata.createdOn,
      body.properties.metadata.updatedBy,
      body.properties.metadata.updatedOn,
    ]
  }

  depends_on = [azapi_resource.alz_policy_set_definitions]
}

# =============================================================================
# デプロイ: ポリシー用ロール割り当て（DINE/Modify ポリシーの実行権限）
# =============================================================================

resource "azapi_resource" "alz_policy_role_assignments" {
  for_each = local.alz_policy_role_assignments

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = each.key
  parent_id = each.value.scope
  body = {
    properties = {
      principalId      = each.value.principal_id
      roleDefinitionId = each.value.role_definition_id
      description      = "Created by ALZ Terraform. Assignment required for Azure Policy."
      principalType    = "ServicePrincipal"
    }
  }
  replace_triggers_external_values = [
    each.value.principal_id,
    each.value.role_definition_id,
  ]
  response_export_values = []

  depends_on = [azapi_resource.private_dns_zone]

  lifecycle {
    ignore_changes = [output.properties.updatedOn]
  }
}

# =============================================================================
# デプロイ: カスタムロール定義
# =============================================================================

resource "azapi_resource" "alz_role_definitions" {
  for_each = local.alz_role_definitions

  type      = "Microsoft.Authorization/roleDefinitions@2022-04-01"
  name      = each.value.role_definition.name
  parent_id = "/providers/Microsoft.Management/managementGroups/${each.value.mg}"
  body = {
    properties = each.value.role_definition.properties
  }
  response_export_values = []

  retry = {
    error_message_regex  = ["not found", "NotFound", "AuthorizationFailed"]
    interval_seconds     = 15
    max_interval_seconds = 120
  }

  depends_on = [time_sleep.wait_for_root_mg]
}
