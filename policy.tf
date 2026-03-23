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
      ref  = "2026.01.3"
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

# --- ガードレール・CMK 強制化オーバーライド ---
#
# ALZ ライブラリのデフォルトでは全ガードレールが enforcementMode=DoNotEnforce
# （段階的有効化の推奨設計）。本リポジトリでは Default（強制）に切り替え、
# 免除が必要なリソースは lib/policy_exemptions/ YAML で個別管理する。

locals {
  guardrail_enforcement_overrides = merge(
    # 標準の DoNotEnforce → Default 切り替え（28 ポリシー）
    { for name in [
      "Enforce-Encrypt-CMK0",
      "Enforce-GR-APIM0",
      "Enforce-GR-AppServices0",
      "Enforce-GR-Automation0",
      "Enforce-GR-BotService0",
      "Enforce-GR-CogServ0",
      "Enforce-GR-Compute0",
      "Enforce-GR-ContApps0",
      "Enforce-GR-ContInst0",
      "Enforce-GR-ContReg0",
      "Enforce-GR-CosmosDb0",
      "Enforce-GR-DataExpl0",
      "Enforce-GR-DataFactory0",
      "Enforce-GR-EventGrid0",
      "Enforce-GR-EventHub0",
      "Enforce-GR-KeyVaultSup0",
      "Enforce-GR-Kubernetes0",
      "Enforce-GR-MachLearn0",
      "Enforce-GR-MySQL0",
      "Enforce-GR-OpenAI0",
      "Enforce-GR-PostgreSQL0",
      "Enforce-GR-SQL0",
      "Enforce-GR-ServiceBus0",
      "Enforce-GR-Storage0",
      "Enforce-GR-Synapse0",
      "Enforce-GR-VirtualDesk0",
      "Enforce-Subnet-Private",
    ] : name => { enforcement_mode = "Default" } },
    # Network GR: DDoS Modify を無効化（DDoS Protection Plan 未契約のため）
    {
      Enforce-GR-Network0 = {
        enforcement_mode = "Default"
        parameters = {
          vnetModifyDdos = jsonencode({ value = "Disabled" })
        }
      }
    }
  )
}

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
    # ALZ: DDoS Protection
    # =========================================================================
    # DDoS Protection Plan は未契約だが、ダミー値が必要（未設定だとプロバイダーエラー）。
    # Enable-DDoS-VNET は connectivity/landing_zones から除外済み。
    # Enforce-GR-Network0 の vnetModifyDdos も Disabled にオーバーライド済み。
    ddos_protection_plan_id = jsonencode({
      value = "/subscriptions/${var.subscription_ids["connectivity"]}/resourceGroups/rg-ddos-${var.primary_location}/providers/Microsoft.Network/ddosProtectionPlans/ddos-${var.primary_location}"
    })

    # =========================================================================
    # ALZ: MDFC (Microsoft Defender for Cloud)
    # =========================================================================
    email_security_contact = jsonencode({
      value = length(var.amba_alert_email) > 0 ? var.amba_alert_email[0] : "security@example.com"
    })

    resource_group_name_mdfc = jsonencode({
      value = "rg-mdfc-export-${var.primary_location}"
    })

    # =========================================================================
    # ALZ: Resource Group Location / Service Health
    # =========================================================================
    resource_group_location = jsonencode({
      value = var.primary_location
    })

    resource_group_name_service_health_alerts = jsonencode({
      value = "rg-service-health-alerts-${var.primary_location}"
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
    })

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

  # ===========================================================================
  # Defender for Cloud 全プラン有効化
  # ===========================================================================
  # ALZ ライブラリのデフォルトでは Deploy-MDFC-Config-H224 の全プランが
  # "Disabled" のため、ここで DeployIfNotExists にオーバーライドします。
  #
  # ガードレール・CMK は DoNotEnforce → Default（強制）に切り替え。
  # 免除が必要なリソースは lib/policy_exemptions/ YAML で個別管理する。
  policy_assignments_to_modify = {
    # Root: MDFC 全プラン有効化
    (var.root_id) = {
      policy_assignments = {
        Deploy-MDFC-Config-H224 = {
          parameters = {
            enableAscForServers                         = jsonencode({ value = "DeployIfNotExists" })
            enableAscForServersVulnerabilityAssessments = jsonencode({ value = "DeployIfNotExists" })
            enableAscForSql                             = jsonencode({ value = "DeployIfNotExists" })
            enableAscForAppServices                     = jsonencode({ value = "DeployIfNotExists" })
            enableAscForStorage                         = jsonencode({ value = "DeployIfNotExists" })
            enableAscForContainers                      = jsonencode({ value = "DeployIfNotExists" })
            enableAscForKeyVault                        = jsonencode({ value = "DeployIfNotExists" })
            enableAscForSqlOnVm                         = jsonencode({ value = "DeployIfNotExists" })
            enableAscForArm                             = jsonencode({ value = "DeployIfNotExists" })
            enableAscForOssDb                           = jsonencode({ value = "DeployIfNotExists" })
            enableAscForCosmosDbs                       = jsonencode({ value = "DeployIfNotExists" })
            enableAscForCspm                            = jsonencode({ value = "DeployIfNotExists" })
          }
        }
      }
    }
    # Platform: ガードレール・CMK 強制化
    "${var.root_id}-platform" = {
      policy_assignments = local.guardrail_enforcement_overrides
    }
    # Landing Zones: ガードレール・CMK 強制化
    "${var.root_id}-landingzones" = {
      policy_assignments = local.guardrail_enforcement_overrides
    }
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

  depends_on = [time_sleep.wait_for_mg_rbac]
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
      description     = lookup(each.value.assignment.properties, "description", null)
      displayName     = lookup(each.value.assignment.properties, "displayName", null)
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
      identity,
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

  # MG 作成後の RBAC 伝播遅延で AuthorizationFailed が発生する場合がある
  retry = {
    error_message_regex  = ["AuthorizationFailed"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }

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
