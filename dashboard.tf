# =============================================================================
# 基盤管理・運用ダッシュボード（Azure Monitor Workbook）
# =============================================================================
#
# 設計方針:
#   - Terraform で完全管理（変更は PR → レビュー → apply。GUI 編集に依存しない）
#   - Workbook を選択した理由:
#     1. パラメータ（時間範囲）によるグローバルフィルタリング
#     2. KQL / Azure Resource Graph による柔軟なクエリ
#     3. タブ構造で運用領域ごとに情報を整理
#     4. RG 内の RBAC で自動共有（別途共有ダッシュボード設定不要）
#   - Portal Dashboard（azurerm_portal_dashboard）ではなく Workbook にした理由:
#     Portal Dashboard はピン留めベースで KQL 柔軟性が低く、
#     Terraform での JSON 定義が冗長。Workbook は構造化しやすい。
#
# アクセス:
#   Azure Portal → Monitor → Workbooks → 「基盤管理・運用ダッシュボード」
#   または Management RG → Workbooks から確認可能
# =============================================================================

locals {
  ops_workbook_id = format("%s-%s-%s-%s-%s",
    substr(md5("ops-workbook-${var.root_id}"), 0, 8),
    substr(md5("ops-workbook-${var.root_id}"), 8, 4),
    substr(md5("ops-workbook-${var.root_id}"), 12, 4),
    substr(md5("ops-workbook-${var.root_id}"), 16, 4),
    substr(md5("ops-workbook-${var.root_id}"), 20, 12)
  )

  # 共通参照
  law_id_lower = lower(azurerm_log_analytics_workspace.main.id)
  root_mg_id   = azurerm_management_group.root.id

  # ---- Workbook 構造 ----
  workbook_items = concat(
    local.wb_header,
    local.wb_parameters,
    local.wb_tabs,
    local.wb_tab_overview,
    local.wb_tab_security,
    local.wb_tab_network,
    local.wb_tab_compute,
    local.wb_tab_compliance,
    local.wb_tab_cost_capacity,
  )

  # ========================================================
  # ヘッダー
  # ========================================================
  wb_header = [
    {
      type = 1
      content = {
        json = join("\n", [
          "# 基盤管理・運用ダッシュボード",
          "ALZ 基盤の監視・運用状況を一元的に表示します。",
        ])
      }
      name = "heading"
    },
  ]

  # ========================================================
  # グローバルパラメータ（時間範囲）
  # ========================================================
  wb_parameters = [
    {
      type = 9
      content = {
        version = "KqlParameterItem/1.0"
        parameters = [
          {
            id         = "time-range"
            version    = "KqlParameterItem/1.0"
            name       = "TimeRange"
            type       = 4
            isRequired = true
            typeSettings = {
              selectableValues = [
                { durationMs = 3600000, displayText = "過去 1 時間" },
                { durationMs = 14400000, displayText = "過去 4 時間" },
                { durationMs = 86400000, displayText = "過去 24 時間" },
                { durationMs = 259200000, displayText = "過去 3 日間" },
                { durationMs = 604800000, displayText = "過去 7 日間" },
                { durationMs = 2592000000, displayText = "過去 30 日間" },
              ]
              allowCustom = true
            }
            value = { durationMs = 86400000 }
          },
        ]
        style = "pills"
      }
      name = "parameters"
    },
  ]

  # ========================================================
  # タブ定義
  # ========================================================
  wb_tabs = [
    {
      type = 11
      content = {
        version = "LinkItem/1.0"
        style   = "tabs"
        links = [
          { id = "tab-overview", cellValue = "overview", linkTarget = "parameter", linkLabel = "概要", subTarget = "selectedTab", style = "link" },
          { id = "tab-security", cellValue = "security", linkTarget = "parameter", linkLabel = "セキュリティ", subTarget = "selectedTab", style = "link" },
          { id = "tab-network", cellValue = "network", linkTarget = "parameter", linkLabel = "ネットワーク", subTarget = "selectedTab", style = "link" },
          { id = "tab-compute", cellValue = "compute", linkTarget = "parameter", linkLabel = "コンピュート", subTarget = "selectedTab", style = "link" },
          { id = "tab-compliance", cellValue = "compliance", linkTarget = "parameter", linkLabel = "コンプライアンス", subTarget = "selectedTab", style = "link" },
          { id = "tab-cost", cellValue = "cost", linkTarget = "parameter", linkLabel = "コスト・容量", subTarget = "selectedTab", style = "link" },
        ]
      }
      name = "tabs"
    },
  ]

  # ========================================================
  # タブ 1: 概要
  # ========================================================
  wb_tab_overview = [
    {
      type = 12
      content = {
        version   = "NotebookGroup/1.0"
        groupType = "editable"
        items = [
          # --- アクティブアラート ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "SecurityAlert",
                "| where TimeGenerated {TimeRange}",
                "| where AlertSeverity in ('High', 'Medium', 'Low')",
                "| summarize",
                "    High = countif(AlertSeverity == 'High'),",
                "    Medium = countif(AlertSeverity == 'Medium'),",
                "    Low = countif(AlertSeverity == 'Low')",
              ])
              size          = 4
              title         = "アクティブアラート"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "tiles"
              tileSettings = {
                titleContent = { columnMatch = "High", formatter = 12, formatOptions = { palette = "redBright" } }
              }
            }
            name        = "active-alerts"
            customWidth = "33"
          },
          # --- リソース正常性 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "ServiceHealthResources",
                "| where type == 'microsoft.resourcehealth/availabilitystatuses'",
                "| extend status = tostring(properties.availabilityState)",
                "| summarize Count = count() by status",
              ])
              size                    = 4
              title                   = "リソース正常性"
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              crossComponentResources = [local.root_mg_id]
              visualization           = "piechart"
              chartSettings           = { seriesLabelSettings = [{ seriesName = "Available", color = "green" }, { seriesName = "Unavailable", color = "redBright" }, { seriesName = "Degraded", color = "orange" }] }
            }
            name        = "resource-health"
            customWidth = "33"
          },
          # --- エージェント稼働率 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "Heartbeat",
                "| summarize LastHeartbeat = max(TimeGenerated) by Computer",
                "| extend Status = iff(LastHeartbeat < ago(5m), 'Offline', 'Online')",
                "| summarize Count = count() by Status",
              ])
              size          = 4
              title         = "エージェント稼働"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "piechart"
              chartSettings = { seriesLabelSettings = [{ seriesName = "Online", color = "green" }, { seriesName = "Offline", color = "redBright" }] }
            }
            name        = "agent-summary"
            customWidth = "34"
          },
          # --- ポリシーコンプライアンス概要 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "PolicyResources",
                "| where type == 'microsoft.policyinsights/policystates'",
                "| extend state = tostring(properties.complianceState)",
                "| summarize Count = count() by state",
              ])
              size                    = 1
              title                   = "ポリシーコンプライアンス"
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              crossComponentResources = [local.root_mg_id]
              visualization           = "piechart"
              chartSettings           = { seriesLabelSettings = [{ seriesName = "Compliant", color = "green" }, { seriesName = "NonCompliant", color = "redBright" }] }
            }
            name        = "policy-overview"
            customWidth = "50"
          },
          # --- Azure Activity（重要な操作）---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "AzureActivity",
                "| where TimeGenerated {TimeRange}",
                "| where CategoryValue in ('Administrative', 'Security', 'Policy')",
                "| where ActivityStatusValue != 'Started'",
                "| summarize Count = count() by CategoryValue, ActivityStatusValue",
                "| sort by Count desc",
              ])
              size          = 1
              title         = "Azure 管理操作"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "activity-summary"
            customWidth = "50"
          },
          # --- サービス正常性 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "ServiceHealthResources",
                "| where type == 'microsoft.resourcehealth/events'",
                "| extend eventType = tostring(properties.EventType)",
                "| extend status = tostring(properties.Status)",
                "| extend title = tostring(properties.Title)",
                "| extend impactStart = todatetime(properties.ImpactStartTime)",
                "| where status == 'Active'",
                "| project eventType, title, status, impactStart",
                "| sort by impactStart desc",
                "| take 10",
              ])
              size                    = 1
              title                   = "Azure サービス正常性（アクティブイベント）"
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              crossComponentResources = [local.root_mg_id]
              visualization           = "table"
            }
            name = "service-health"
          },
        ]
      }
      conditionalVisibility = {
        parameterName = "selectedTab"
        comparison    = "isEqualTo"
        value         = "overview"
      }
      name = "group-overview"
    },
  ]

  # ========================================================
  # タブ 2: セキュリティ
  # ========================================================
  wb_tab_security = [
    {
      type = 12
      content = {
        version   = "NotebookGroup/1.0"
        groupType = "editable"
        items = [
          # --- セキュリティアラート推移 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "SecurityAlert",
                "| where TimeGenerated {TimeRange}",
                "| summarize Count = count() by AlertSeverity, bin(TimeGenerated, 1h)",
                "| render timechart",
              ])
              size          = 0
              title         = "セキュリティアラート推移"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "timechart"
            }
            name = "security-alerts-trend"
          },
          # --- Sentinel インシデント ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "SecurityIncident",
                "| where TimeGenerated {TimeRange}",
                "| extend severity = tostring(Severity)",
                "| extend status = tostring(Status)",
                "| summarize Count = count() by severity, status",
                "| sort by Count desc",
              ])
              size          = 1
              title         = "Sentinel インシデント"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "sentinel-incidents"
            customWidth = "50"
          },
          # --- 失敗したサインイン ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "SigninLogs",
                "| where TimeGenerated {TimeRange}",
                "| where ResultType != '0'",
                "| summarize FailCount = count() by UserPrincipalName, IPAddress, ResultDescription",
                "| sort by FailCount desc",
                "| take 20",
              ])
              size          = 1
              title         = "失敗したサインイン Top 20"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "failed-signins"
            customWidth = "50"
          },
          # --- 権限変更の監査 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "AuditLogs",
                "| where TimeGenerated {TimeRange}",
                "| where Category in ('RoleManagement', 'GroupManagement', 'UserManagement')",
                "| extend Actor = tostring(InitiatedBy.user.userPrincipalName)",
                "| extend Target = tostring(TargetResources[0].displayName)",
                "| extend Operation = OperationName",
                "| project TimeGenerated, Category, Operation, Actor, Target, Result",
                "| sort by TimeGenerated desc",
                "| take 30",
              ])
              size          = 1
              title         = "Entra ID 権限変更の監査"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name = "audit-role-changes"
          },
          # --- 脅威インテリジェンス検知 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "AZFWThreatIntel",
                "| where TimeGenerated {TimeRange}",
                "| project TimeGenerated, SourceIp, DestinationIp, DestinationPort, Protocol, Action, ThreatDescription",
                "| sort by TimeGenerated desc",
                "| take 50",
              ])
              size          = 1
              title         = "Firewall 脅威インテリジェンス検知"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name = "threat-intel"
          },
        ]
      }
      conditionalVisibility = {
        parameterName = "selectedTab"
        comparison    = "isEqualTo"
        value         = "security"
      }
      name = "group-security"
    },
  ]

  # ========================================================
  # タブ 3: ネットワーク
  # ========================================================
  wb_tab_network = [
    {
      type = 12
      content = {
        version   = "NotebookGroup/1.0"
        groupType = "editable"
        items = [
          # --- Firewall 許可/拒否 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "AZFWNetworkRule",
                "| where TimeGenerated {TimeRange}",
                "| summarize Allowed = countif(Action == 'Allow'), Denied = countif(Action == 'Deny') by bin(TimeGenerated, 1h)",
                "| render timechart",
              ])
              size          = 0
              title         = "ネットワークルール 許可 / 拒否"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "timechart"
            }
            name = "fw-network-rules"
          },
          # --- Firewall アプリケーションルール ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "AZFWApplicationRule",
                "| where TimeGenerated {TimeRange}",
                "| summarize Count = count() by Action, Fqdn",
                "| sort by Count desc",
                "| take 20",
              ])
              size          = 1
              title         = "アプリケーションルール Top 20"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "fw-app-rules"
            customWidth = "50"
          },
          # --- Firewall IDPS ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "AZFWIdpsSignature",
                "| where TimeGenerated {TimeRange}",
                "| summarize HitCount = count() by SignatureId, Description, Severity, Action",
                "| sort by HitCount desc",
                "| take 20",
              ])
              size          = 1
              title         = "Firewall IDPS 検知"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "fw-idps"
            customWidth = "50"
          },
          # --- DNS クエリ統計 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "AZFWDnsQuery",
                "| where TimeGenerated {TimeRange}",
                "| summarize QueryCount = count() by QueryName",
                "| sort by QueryCount desc",
                "| take 20",
              ])
              size          = 1
              title         = "Firewall DNS クエリ Top 20"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "fw-dns"
            customWidth = "50"
          },
          # --- Firewall 拒否フロー ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "AZFWNetworkRule",
                "| where TimeGenerated {TimeRange}",
                "| where Action == 'Deny'",
                "| summarize DenyCount = count() by SourceIp, DestinationIp, DestinationPort, Protocol",
                "| sort by DenyCount desc",
                "| take 20",
              ])
              size          = 1
              title         = "拒否されたフロー Top 20"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "fw-denied-flows"
            customWidth = "50"
          },
        ]
      }
      conditionalVisibility = {
        parameterName = "selectedTab"
        comparison    = "isEqualTo"
        value         = "network"
      }
      name = "group-network"
    },
  ]

  # ========================================================
  # タブ 4: コンピュート
  # ========================================================
  wb_tab_compute = [
    {
      type = 12
      content = {
        version   = "NotebookGroup/1.0"
        groupType = "editable"
        items = [
          # --- エージェント一覧 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "Heartbeat",
                "| summarize LastHeartbeat = max(TimeGenerated) by Computer, OSType, Version, ComputerIP",
                "| extend Status = iff(LastHeartbeat < ago(5m), '🔴 Offline', '🟢 Online')",
                "| sort by Status asc, Computer asc",
              ])
              size          = 1
              title         = "エージェント一覧"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name = "agent-list"
          },
          # --- CPU 使用率 Top VM ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "InsightsMetrics",
                "| where TimeGenerated {TimeRange}",
                "| where Namespace == 'Processor' and Name == 'UtilizationPercentage'",
                "| summarize AvgCPU = round(avg(Val), 1), MaxCPU = round(max(Val), 1) by Computer",
                "| sort by AvgCPU desc",
                "| take 15",
              ])
              size          = 1
              title         = "CPU 使用率（平均・最大）"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "cpu-usage"
            customWidth = "50"
          },
          # --- メモリ使用率 Top VM ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "InsightsMetrics",
                "| where TimeGenerated {TimeRange}",
                "| where Namespace == 'Memory' and Name == 'AvailableMB'",
                "| summarize AvgAvailMB = round(avg(Val), 0), MinAvailMB = round(min(Val), 0) by Computer",
                "| sort by AvgAvailMB asc",
                "| take 15",
              ])
              size          = 1
              title         = "メモリ空き容量（平均・最小）"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "memory-usage"
            customWidth = "50"
          },
          # --- 構成変更 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "ConfigurationChange",
                "| where TimeGenerated {TimeRange}",
                "| summarize Changes = count() by Computer, ConfigChangeType",
                "| sort by Changes desc",
                "| take 30",
              ])
              size          = 1
              title         = "構成変更"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "config-changes"
            customWidth = "50"
          },
          # --- 更新コンプライアンス ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "UpdateSummary",
                "| where TimeGenerated {TimeRange}",
                "| summarize arg_max(TimeGenerated, *) by Computer",
                "| project Computer, OsVersion,",
                "    CriticalMissing = CriticalUpdatesMissing,",
                "    SecurityMissing = SecurityUpdatesMissing,",
                "    OtherMissing = OtherUpdatesMissing,",
                "    LastAssessed = TimeGenerated",
                "| sort by CriticalMissing desc",
              ])
              size          = 1
              title         = "パッチ適用状況"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "table"
            }
            name        = "update-compliance"
            customWidth = "50"
          },
        ]
      }
      conditionalVisibility = {
        parameterName = "selectedTab"
        comparison    = "isEqualTo"
        value         = "compute"
      }
      name = "group-compute"
    },
  ]

  # ========================================================
  # タブ 5: コンプライアンス
  # ========================================================
  wb_tab_compliance = [
    {
      type = 12
      content = {
        version   = "NotebookGroup/1.0"
        groupType = "editable"
        items = [
          # --- 管理グループ別コンプライアンス ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "PolicyResources",
                "| where type == 'microsoft.policyinsights/policystates'",
                "| extend mgId = tostring(properties.managementGroupIds)",
                "| extend state = tostring(properties.complianceState)",
                "| summarize Compliant = countif(state == 'Compliant'), NonCompliant = countif(state == 'NonCompliant') by mgId",
                "| extend ComplianceRate = round(100.0 * Compliant / (Compliant + NonCompliant), 1)",
                "| sort by ComplianceRate asc",
              ])
              size                    = 1
              title                   = "管理グループ別コンプライアンス率"
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              crossComponentResources = [local.root_mg_id]
              visualization           = "table"
            }
            name = "compliance-by-mg"
          },
          # --- 非準拠ポリシー Top 20 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "PolicyResources",
                "| where type == 'microsoft.policyinsights/policystates'",
                "| where properties.complianceState == 'NonCompliant'",
                "| extend policyName = tostring(properties.policyDefinitionName)",
                "| extend policyType = tostring(properties.policyDefinitionAction)",
                "| summarize NonCompliant = count() by policyName, policyType",
                "| sort by NonCompliant desc",
                "| take 20",
              ])
              size                    = 1
              title                   = "非準拠リソースが多いポリシー Top 20"
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              crossComponentResources = [local.root_mg_id]
              visualization           = "table"
            }
            name        = "noncompliant-policies"
            customWidth = "50"
          },
          # --- 非準拠リソース詳細 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "PolicyResources",
                "| where type == 'microsoft.policyinsights/policystates'",
                "| where properties.complianceState == 'NonCompliant'",
                "| extend resourceId = tostring(properties.resourceId)",
                "| extend resourceType = tostring(properties.resourceType)",
                "| extend policyName = tostring(properties.policyDefinitionName)",
                "| project resourceId, resourceType, policyName",
                "| take 50",
              ])
              size                    = 1
              title                   = "非準拠リソース一覧"
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              crossComponentResources = [local.root_mg_id]
              visualization           = "table"
            }
            name        = "noncompliant-resources"
            customWidth = "50"
          },
          # --- IaC 非準拠（deployed_by タグなし）---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "Resources",
                "| where isempty(tags.deployed_by) or tags.deployed_by != 'terraform'",
                "| where type !in ('microsoft.managementgroups/managementgroups',",
                "    'microsoft.authorization/policyassignments',",
                "    'microsoft.authorization/roledefinitions',",
                "    'microsoft.authorization/roleassignments')",
                "| summarize Count = count() by type, subscriptionId",
                "| sort by Count desc",
                "| take 30",
              ])
              size                    = 1
              title                   = "Terraform 管理外リソース（deployed_by タグなし）"
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              crossComponentResources = [local.root_mg_id]
              visualization           = "table"
            }
            name = "iac-drift"
          },
        ]
      }
      conditionalVisibility = {
        parameterName = "selectedTab"
        comparison    = "isEqualTo"
        value         = "compliance"
      }
      name = "group-compliance"
    },
  ]

  # ========================================================
  # タブ 6: コスト・容量
  # ========================================================
  wb_tab_cost_capacity = [
    {
      type = 12
      content = {
        version   = "NotebookGroup/1.0"
        groupType = "editable"
        items = [
          # --- LAW データ取り込み量（テーブル別） ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "Usage",
                "| where TimeGenerated {TimeRange}",
                "| summarize IngestGB = round(sum(Quantity) / 1000, 2) by DataType",
                "| sort by IngestGB desc",
                "| take 20",
              ])
              size          = 1
              title         = "LAW データ取り込み量（テーブル別）"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "barchart"
            }
            name        = "ingestion-by-table"
            customWidth = "50"
          },
          # --- LAW データ取り込みトレンド ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "Usage",
                "| where TimeGenerated {TimeRange}",
                "| summarize DailyGB = round(sum(Quantity) / 1000, 2) by bin(TimeGenerated, 1d)",
                "| render timechart",
              ])
              size          = 0
              title         = "LAW データ取り込みトレンド（日次）"
              queryType     = 0
              resourceType  = "microsoft.operationalinsights/workspaces"
              visualization = "timechart"
            }
            name        = "ingestion-trend"
            customWidth = "50"
          },
          # --- サブスクリプション別リソース数 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "Resources",
                "| summarize Count = count() by subscriptionId, type",
                "| summarize ResourceCount = sum(Count), TypeCount = dcount(type) by subscriptionId",
                "| sort by ResourceCount desc",
              ])
              size                    = 1
              title                   = "サブスクリプション別リソース数"
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              crossComponentResources = [local.root_mg_id]
              visualization           = "table"
            }
            name        = "resource-count"
            customWidth = "50"
          },
          # --- ストレージアカウント一覧 ---
          {
            type = 3
            content = {
              version = "KqlItem/1.0"
              query = join("\n", [
                "Resources",
                "| where type == 'microsoft.storage/storageaccounts'",
                "| extend kind = tostring(properties.kind)",
                "| extend sku = tostring(sku.name)",
                "| project name, resourceGroup, subscriptionId, kind, sku, location",
              ])
              size                    = 1
              title                   = "ストレージアカウント一覧"
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              crossComponentResources = [local.root_mg_id]
              visualization           = "table"
            }
            name        = "storage-accounts"
            customWidth = "50"
          },
        ]
      }
      conditionalVisibility = {
        parameterName = "selectedTab"
        comparison    = "isEqualTo"
        value         = "cost"
      }
      name = "group-cost"
    },
  ]
}

# =============================================================================
# Workbook リソース
# =============================================================================

resource "azurerm_application_insights_workbook" "ops" {
  count    = var.ops_dashboard_enabled ? 1 : 0
  provider = azurerm.management

  name                = local.ops_workbook_id
  resource_group_name = azurerm_resource_group.management.name
  location            = var.primary_location
  display_name        = "基盤管理・運用ダッシュボード"
  source_id           = local.law_id_lower
  category            = "workbook"

  data_json = jsonencode({
    version             = "Notebook/1.0"
    items               = local.workbook_items
    fallbackResourceIds = [local.law_id_lower]
  })

  tags = var.tags
}
