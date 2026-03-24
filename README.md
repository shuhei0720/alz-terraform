# ALZ-terraform — Azure Landing Zone

本プロジェクトは、AVM（Azure Verified Modules）を使わず、`azurerm` / `azapi` リソースのみで構築した Azure Landing Zone です。
すべてのコードが可視で、外部モジュールへの依存をできるだけ少なくしています。

> **想定読者**: Terraform の経験、 Azure の経験のある方。
> Terraform とAzureの基礎は既知として説明します。

---

## 目次

1. [設計思想](#設計思想)
2. [全体アーキテクチャ](#全体アーキテクチャ)
3. [ファイル構成と役割](#ファイル構成と役割)
4. [管理グループ階層](#管理グループ階層)
5. [ネットワーク設計（Hub-Spoke）](#ネットワーク設計hub-spoke)
6. [ポリシーシステム（3 層カスタマイズ）](#ポリシーシステム3-層カスタマイズ)
7. [サブスクリプション自動払い出し（Vending）](#サブスクリプション自動払い出しvending)
8. [監視基盤](#監視基盤)
9. [セキュリティ & ガバナンス](#セキュリティ--ガバナンス)
10. [セットアップ手順](#セットアップ手順)
11. [GitHub Actions CI/CD](#github-actions-cicd)
12. [構成ドリフト検知](#構成ドリフト検知)
13. [依存バージョン管理](#依存バージョン管理)
14. [技術補足](#技術補足)
15. [よくある質問（FAQ）](#よくある質問)

---

## 設計思想

### なぜ AVM を使わないのか

Azure Verified Modules (AVM) とは、Microsoftが用意しているTerraformのモジュールです。

[参考：Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)

Azure Verified Modules (AVM) は便利ですが、モジュール内部がブラックボックスになりがちで、外部コードに依存します。
本構成は以下の方針で設計しました。

| 方針 | 説明 |
|:---|:---|
| **全コード可視** | 外部モジュールを使わず、全リソースを `.tf` ファイルに直接記述しています。何が作られるか、コードを読めば 100% わかります。実際の構成から逸脱の無いパラメーターシートになります。 |
| **ディレクトリ完結** | このリポジトリのファイルだけで Landing Zone 全体が動きます。モジュール依存の追跡が不要なのででコードの理解が容易になります。 |
| **YAML 駆動のセルフサービス** | サブスクリプション追加は YAML ファイル 1 つ置くだけ。Terraform コードの編集不要で、安全に運用できます。 |
| **1 回の apply で完走** | Azure API の一時的エラーに対してできるだけリトライを実装し、再 apply なしでデプロイが完了するよう配慮しています。 |

### プロバイダーの役割分担

本構成は 4 つの Terraform プロバイダーを使います。

[参考：Azure Terraform プロバイダー](https://learn.microsoft.com/ja-jp/azure/developer/terraform/overview)

![プロバイダーの役割分担](diagrams/readme-01-provider-architecture.svg)

**ポイント**: `azurerm` はサブスクリプションごとに `provider alias` が必要ですが、`azapi` はフルリソース ID で任意のサブスクリプションを操作できます。サブスクリプション自動払い出し（Vending）で新しいサブスクリプションが増えても、provider 定義の追加が不要です。

---

## 全体アーキテクチャ
本リポジトリでは、以下のようなアーキテクチャをデプロイします。
全社でAzureを使うための共通基盤になります。

[参考：Azure ランディング ゾーン アーキテクチャ](https://learn.microsoft.com/ja-jp/azure/cloud-adoption-framework/ready/landing-zone/)

![全体アーキテクチャ](diagrams/readme-02-overall-architecture.svg)

---

## ファイル構成と役割

```
alz-terraform/
│
│  ── Terraform 基盤 ──────────────────────────────────────────
├── terraform.tf                  # プロバイダー定義・バージョン制約
├── variables.tf                  # 全入力変数（19 変数）
├── locals.tf                     # 計算値（Hub キー、DNS×VNet 直積）
├── outputs.tf                    # 出力値（16 個）
├── terraform.tfvars              # 環境固有の設定値
├── terraform.tfvars.example      # 上記の記入例
│
│  ── リソース定義 ────────────────────────────────────────────
├── management-groups.tf          # 管理グループ 11 個 + サブスクリプション配置
├── resource-groups.tf            # リソースグループ 4 種
├── management-resources.tf       # Log Analytics, Sentinel, UAMI, DCR × 3, LAW アーカイブ
├── network-hub.tf                # Hub VNet, Firewall, Bastion, DNS Resolver, ExpressRoute, ルートテーブル
├── network-dns.tf                # Private DNS ゾーン 56 個 + VNet リンク
├── policy.tf                     # ポリシーデプロイエンジン（ガードレール強制化含む）
├── policy-exemptions.tf          # ポリシー適用除外（グローバル + サブスク YAML から展開）
├── subscription-vending.tf       # YAML 駆動のサブスクリプション自動払い出し + Spoke アラートルーティング
│
│  ── ポリシーライブラリ ──────────────────────────────────────
├── lib/
│   ├── alz_library_metadata.json          # ライブラリメタデータ
│   ├── architecture_definitions/          # MG ↔ アーキタイプのマッピング
│   │   └── alz_with_amba.*.json           # ALZ + AMBA 統合定義
│   ├── archetype_definitions/             # アーキタイプオーバーライド（17 YAML）
│   │   ├── root_custom.yaml              #   ← カスタムポリシー追加
│   │   ├── platform_custom.yaml          #   ← IaC 準拠ポリシー割り当て
│   │   ├── landing_zones_custom.yaml     #   ← DDoS ポリシー除外
│   │   ├── amba_root_custom.yaml         #   ← AMBA アラートポリシー
│   │   └── ... (残り 13 ファイル)
│   ├── policy_definitions/                # カスタムポリシー定義
│   │   └── Audit-Non-Terraform-Resources.*.json
│   ├── policy_set_definitions/            # カスタムイニシアティブ
│   │   └── IaC-Compliance-Initiative.*.json
│   ├── policy_assignments/                # カスタム割り当て
│   │   └── Assign-IaC-Compliance.*.json
│   └── policy_exemptions/                 # ポリシー適用除外（スコープ指定）
│       └── exemptions.yaml                # グローバルポリシー適用除外
│
│  ── サブスクリプション定義 ──────────────────────────────────
├── subscriptions/
│   ├── test-subscription.yaml             # テスト用サブスクリプション
│   └── templates/
│       ├── corp-template.yaml             # Corp 用テンプレート
│       └── online-template.yaml           # Online 用テンプレート
│
│  ── CI/CD ────────────────────────────────────────────────────
└── .github/
    ├── workflows/
    │   ├── ci.yaml                        # PR 時: fmt + validate + plan
    │   ├── cd.yaml                        # main マージ時: apply / 手動 destroy
    │   ├── drift-detection.yaml           # 毎日: 構成ドリフト検知 → Issue
    │   ├── dependency-check.yaml          # PR 時: プロバイダー SemVer 分析 + lock 検証
    │   ├── library-update-check.yaml      # 毎週: ALZ/AMBA ライブラリ更新検知 → Issue
    │   ├── policy-remediation.yaml        # 手動: DINE/Modify ポリシーの修復タスク作成
    │   └── provider-major-check.yaml      # 毎週: プロバイダーメジャー更新検知 → Issue
    └── ISSUE_TEMPLATE/
        └── library-update-body.md         # ライブラリ更新 Issue のテンプレート
```

### ファイルの読み方と使い方

| やりたいこと | 読むファイル |
|:---|:---|
| 新しいサブスクリプションを追加したい | `subscriptions/templates/` → コピーして YAML を編集 |
| ALZのポリシーを除外したい | `lib/archetype_definitions/` のコメント行を解除 |
| カスタムポリシーを追加したい | `lib/policy_definitions/` に JSON 追加し、`archetype`にポリシー定義を追加 |
| 特定リソースをポリシーから適用除外したい | `lib/policy_exemptions/` または `subscriptions/<name>.yaml` の `policy_exemptions`（[ポリシー適用除外](#ポリシー適用除外exemptions)参照） |
| Firewall ルールを変更したい | `network-hub.tf` の `azurerm_firewall_policy_rule_collection_group`に追記 |
| Hub VNet の IP 範囲を変更したい | `terraform.tfvars` の `hub_virtual_networks` |
| 新しい DCR を追加したい | `management-resources.tf` にリソース追加 |
| デプロイが失敗した場合の調査 | [リトライメカニズム一覧](#リトライメカニズム一覧) を確認 |
| Spoke のアラート通知先を変更したい | `subscriptions/*.yaml` の `alert_contacts` を編集 |

---

## 管理グループ階層

管理グループ (Management Group) は、Azure サブスクリプションを階層的にグループ化し、ポリシーとアクセス制御を一括適用する仕組みです。

![管理グループ階層](diagrams/readme-03-management-group-hierarchy.svg)

### 仕組み

- **Root MG** にポリシーを割り当てると、配下の全サブスクリプションに継承されます
- **Platform MG** のポリシーは Platform 配下のみ、**Landing Zones MG** のポリシーは LZ 配下のみに適用
- サブスクリプションを別の MG に移動するだけで、適用されるポリシーが切り替わります

### サブスクリプションの配置

| サブスクリプション | 管理グループ | 用途 |
|:---|:---|:---|
| Management | Platform > Management | LAW, Sentinel, UAMI, DCR |
| Connectivity | Platform > Connectivity | Hub VNet, Firewall, DNS, ER |
| Identity | Platform > Identity | AD 関連（将来拡張） |
| Security | Platform > Security | セキュリティ運用（将来拡張） |
| ワークロード系 | Landing Zones > Corp or Online | アプリケーション環境 |

### 管理グループの追加

新しい管理グループ（例: `Confidential`）を Landing Zones 配下に追加する場合、**3 箇所を同時に変更**します。

#### Step 1: management-groups.tf にリソース追加

```hcl
resource "azurerm_management_group" "confidential" {
  name                       = "${var.root_id}-confidential"
  display_name               = "Confidential"
  parent_management_group_id = azurerm_management_group.landing_zones.id
}
```

`time_sleep.wait_for_mg_rbac` の `depends_on` リストにも新しい MG を追加してください。
追加しないと、RBAC 伝搬完了前にポリシー割り当てが走り失敗する可能性があります。

#### Step 2: lib/architecture_definitions/alz_with_amba.alz_architecture_definition.json にエントリ追加

```json
{
  "archetypes": ["confidential_custom"],
  "display_name": "Confidential",
  "exists": true,
  "id": "alz-confidential",
  "parent_id": "alz-landingzones"
}
```

- `id` は `${root_id}-<MG名>` と一致させる（root_id が `alz` なら `alz-confidential`）
- `exists: true` — Terraform でリソースを作るので `true`

#### Step 3: lib/archetype_definitions/ に archetype override YAML 作成

```yaml
# lib/archetype_definitions/confidential_custom.alz_archetype_override.yaml
base_archetype: corp          # ベースにする既存 archetype（corp, online 等）
name: confidential_custom

policy_assignments_to_add: []
policy_assignments_to_remove: []
policy_definitions_to_add: []
policy_definitions_to_remove: []
```

`base_archetype` に既存の archetype を指定すると、そのポリシーセットを継承した上で追加・除外ができます。

> **注意**: management-groups.tf と architecture_definition.json の整合性を必ず保ってください。片方だけ変更するとポリシー割り当てが壊れます。

### 管理グループ階層の変更

MG の親を変更する場合は、以下の 2 箇所の `parent` を同時に変更します。

| ファイル | 変更箇所 |
|:---|:---|
| `management-groups.tf` | `parent_management_group_id` |
| `alz_with_amba.alz_architecture_definition.json` | `parent_id` |

Terraform が MG の移動を検知し、`apply` で自動的に反映します。

### 基盤サブスクリプションの追加

基盤（Platform）サブスクリプションを追加する場合（例: `Network` サブスクリプション）、以下を変更します。

#### Step 1: variables.tf の subscription_ids に追加

```hcl
variable "subscription_ids" {
  # ...
  validation {
    condition = alltrue([
      for key in ["management", "connectivity", "identity", "security", "network"] :  # ← 追加
      contains(keys(var.subscription_ids), key)
    ])
  }
}
```

#### Step 2: terraform.tfvars にサブスクリプション ID を追加

```hcl
subscription_ids = {
  management   = "..."
  connectivity = "..."
  identity     = "..."
  security     = "..."
  network      = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # ← 追加
}
```

#### Step 3: management-groups.tf に MG 関連付けを追加

```hcl
# 管理グループを新規作成する場合（上記「管理グループの追加」の手順も実施）
resource "azurerm_management_group_subscription_association" "network" {
  management_group_id = azurerm_management_group.network.id               # or 既存 MG
  subscription_id     = "/subscriptions/${var.subscription_ids["network"]}"
}
```

#### Step 4: 必要に応じてリソースを追加

新しい基盤サブスクリプション用のリソース（RG, VNet, 監視設定等）を対応する `.tf` ファイルに追加します。
Connectivity サブスクリプションのように `azurerm` の provider alias が必要な場合は、`terraform.tf` にも追加してください。

> **ワークロード系サブスクリプション**の追加は、上記の手順は不要です。`subscriptions/` に YAML を 1 つ配置するだけで自動的に払い出されます。詳細は[サブスクリプション自動払い出し（Vending）](#サブスクリプション自動払い出しvending)を参照してください。

---

## ネットワーク設計（Hub-Spoke）

### 概要

Hub-Spoke トポロジーは、中央の Hub VNet に共通のネットワーク機能（Firewall, Gateway, DNS, Bastion）を集約し、各ワークロードの Spoke VNet をピアリングで接続する設計です。

![Hub-Spoke ネットワーク トポロジ](diagrams/readme-04-hub-spoke-network.svg)

### Hub VNet のサブネット構成

| サブネット | 用途 | 備考 |
|:---|:---|:---|
| `AzureFirewallSubnet` | Azure Firewall 専用 | 名前固定（Azure の要件） |
| `GatewaySubnet` | VPN/ER Gateway 専用 | 名前固定（Azure の要件） |
| `AzureBastionSubnet` | Azure Bastion 専用 | 名前固定、条件付き作成 |
| `AzureFirewallManagementSubnet` | Firewall 管理用 | 強制トンネリング時に必要 |
| `InboundEndpointSubnet` | Private DNS Resolver インバウンド | DNS クエリ受信用、delegation 付き |
| `OutboundEndpointSubnet` | Private DNS Resolver アウトバウンド | DNS クエリ転送用、delegation 付き |

### ルーティングの仕組み

トラフィックの流れを理解するのが Hub-Spoke で最も重要なポイントです。

#### Spoke → インターネット

```
Spoke VM → UDR (0.0.0.0/0 → Firewall IP) → Azure Firewall → インターネット
```

各 Spoke サブネットにはルートテーブル `rt-spoke-to-fw` が関連付けられています。
デフォルトルート (0.0.0.0/0) の宛先が Azure Firewall の内部 IP になっているため、Spoke からの全トラフィックが Firewall を通過します。

#### Spoke → オンプレミス（Corp のみ）

```
Spoke VM → UDR → Firewall → ER Gateway → ExpressRoute → オンプレミス
```

Corp サブスクリプションの Spoke VNet では `use_hub_gateway: true` が設定されています。
これにより、VNet ピアリングで `useRemoteGateways` が有効になり、ExpressRoute 経由のオンプレミスルートが Spoke に伝搬されます。

#### オンプレミス → Spoke

```
オンプレミス → ExpressRoute → ER Gateway → GatewaySubnet RT → Firewall → Spoke VM
```

GatewaySubnet のルートテーブルに各 Spoke VNet の CIDR → Firewall のルートが自動追加されるため、オンプレからの通信も Firewall を経由します。

### ExpressRoute

ExpressRoute は、オンプレミスネットワークと Azure を専用線で接続するサービスです。インターネットを経由せず、低レイテンシ・高帯域・高信頼性の接続を提供します。
本構成では ER 回線（箱のみ）と ER Gateway を Hub VNet にデプロイし、オンプレミス接続の準備を整えます。
Gateway SKU はデフォルトで **ErGw1AZ**（ゾーン冗長）を使用し、可用性ゾーン障害時も接続を維持します。

[参考：Azure ExpressRoute とは](https://learn.microsoft.com/ja-jp/azure/expressroute/expressroute-introduction)

#### オンプレミス接続の手順

本構成で作成される ER Circuit と ER Gateway は「箱」だけです。実際にオンプレミスと接続する際の手順は以下のとおりです。

| ステップ | 作業場所 | 内容 |
|:---|:---|:---|
| 1. 回線プロバイダー契約 | Azure Portal + キャリア | ER Circuit の Service Key を取得し、通信キャリア（NTT, KDDI 等）に提供。キャリア側で物理回線を開通 |
| 2. プライベートピアリング構成 | Azure Portal / キャリア | BGP ピアリング（ASN、/30 サブネット）を設定 |
| 3. Connection 作成 | **Terraform** | `connection_enabled = true` に変更して `terraform apply` |

```hcl
# terraform.tfvars — キャリア開通後にフラグを有効化
hub_virtual_networks = {
  primary = {
    # ... 既存設定 ...
    express_route = {
      connection_enabled = true   # ← これを追加
    }
  }
}
```

ステップ 1・2 は Azure Portal / キャリア側の作業ですが、ステップ 3 の Connection は Terraform で管理します。
これにより、接続状態が IaC として記録され、コードレビューが可能です。

#### DR 時の復元手順

DR（全リソース再構築）の場合、ER Circuit が新規作成されるため **Service Key が変わります**。
そのため、以下の 2 段階デプロイが必要です。

| ステップ | 操作 | 理由 |
|:---|:---|:---|
| 1. `connection_enabled = false` で apply | Circuit + Gateway を再作成 | 新しい Circuit はキャリア未接続のため Connection は作れない |
| 2. キャリアに Service Key を再提供 | キャリア側で回線を再開通 | 新しい Service Key で再プロビジョニング |
| 3. `connection_enabled = true` で apply | Connection を作成 | キャリア開通後に Gateway と Circuit をリンク |

> **注意**: `connection_enabled = true` のまま全 DR を実行すると、キャリア未接続の Circuit に対して Connection を作成しようとしてエラーになります。DR 時は必ず `false` から開始してください。

### マルチリージョン Hub と DR 切替

本構成は複数リージョンに Hub VNet をデプロイし、Spoke ごとにピアリング先 Hub を選択できる設計になっています。

#### 設計思想

- **通常時**: 各 Spoke YAML の `virtual_network.hub_key` で接続先 Hub を個別指定
- **DR 時**: `active_hub_key = "secondary"` を設定して `terraform apply` → 全 Spoke を一括切替

```yaml
# subscriptions/my-app.yaml
virtual_network:
  hub_key: "primary"        # このSpokeはprimary Hubに接続
  name: "vnet-my-app"
  hub_peering_enabled: true
  use_hub_gateway: true
```

セカンダリ Hub は常に稼働状態（Firewall, DNS Resolver, Gateway がデプロイ済み）のため、切替後即座に通信可能です。

#### Hub 選択の優先順位

| 優先度 | 条件 | Hub キー |
|:---|:---|:---|
| 1（最優先） | `active_hub_key` が設定されている（DR） | `active_hub_key` の値 |
| 2 | YAML に `hub_key` が指定されている | `virtual_network.hub_key` の値 |
| 3（デフォルト） | いずれも未指定 | `"primary"` |

#### `active_hub_key` / `hub_key` で切り替わるリソース

| リソース | 切替動作 | 通信断 |
|:---|:---|:---|
| **Spoke VNet DNS サーバー** | `azapi_update_resource` で Resolver IP を PATCH | なし（DHCP 更新で反映） |
| **Spoke Route Table** | デフォルトルートの next hop IP を更新 | なし |
| **Spoke↔Hub Peering** | ピアリング先をセカンダリ Hub に切替 | 一時的（apply 中） |
| **Gateway Route** | Primary RT から削除 → Secondary RT に追加 | なし |

#### 切替に影響しないリソース（常に両 Hub にデプロイ済み）

| リソース | 理由 |
|:---|:---|
| **Firewall Rules** | `for_each = var.hub_virtual_networks` で全 Hub に同一ルール複製 |
| **Private DNS Zone Links** | `setproduct(zones, hub_keys)` で全 Hub VNet にリンク済み |
| **Hub-to-Hub Peering** | `hub_peering_pairs` で相互接続済み |

#### DR 切替手順

```bash
# 1. terraform.tfvars に active_hub_key を追加（全 Spoke を強制切替）
active_hub_key = "secondary"

# 2. Plan で影響範囲を確認
terraform plan
# → Spoke VNet DNS, Route Table, Peering が変更対象になることを確認

# 3. Apply
terraform apply

# 4. 復旧後は active_hub_key をコメントアウトまたは削除（YAML の hub_key に戻る）
# active_hub_key = "secondary"
```

> **注意**: Peering の切替中（apply 実行中）は一時的に Spoke↔Hub 間の通信が断たれます。DR（緊急事態）の性質上、この短時間の断は許容されます。

#### corp と online の DR 時の違い

| 設定 | Corp | Online |
|:---|:---|:---|
| `useRemoteGateways` | `true`（ER Gateway 経由のオンプレ接続） | `false` |
| DR 切替時 | Peering + Gateway Route がセカンダリに移動 | Peering のみ切替 |
| オンプレ接続 | セカンダリ ER Gateway 経由に切替 | 対象外 |

Corp の Spoke は ER Gateway 経由のオンプレミス接続があるため、DR 切替時にはセカンダリ側の ER 回線もキャリア開通済みである必要があります。
Online の Spoke はインターネット接続のみのため、Peering とルートテーブルの切替だけで DR が完了します。

### ルートテーブルの設計

| ルートテーブル | 対象 | BGP 伝搬 | 主なルート |
|:---|:---|:---|:---|
| `rt-spoke-to-fw` | Spoke サブネット | **無効** | 0.0.0.0/0 → Firewall |
| `rt-gateway` | GatewaySubnet | **有効** | Spoke CIDR → Firewall |

- `rt-spoke-to-fw`: BGP 伝搬を無効にすることで、ExpressRoute から学習したルートではなく Firewall 経由を強制します
- `rt-gateway`: BGP を有効にしつつ、Spoke 宛の通信だけ Firewall に向けます

### Azure Firewall

Azure Firewall は、Hub VNet にデプロイされるマネージドのクラウドファイアウォールです。全 Spoke VNet のトラフィックを検査・制御し、許可された通信のみを通過させます。

| 設定 | 値 |
|:---|:---|
| **SKU** | Standard（変更可） |
| **脅威インテリジェンス** | Deny（悪意のある通信を自動ブロック） |
| **DNS Proxy** | 有効（Firewall 経由で FQDN ルールを解決） |
| **AzureFirewallポリシー** | Firewall Policy でルールを一元管理 |

DNS Proxy を有効にすることで、アプリケーションルールで FQDN（例: `*.blob.core.windows.net`）を使用できます。

[参考：Azure Firewall とは](https://learn.microsoft.com/ja-jp/azure/firewall/overview)

### Azure Firewall のルール

Spoke環境で共通サービスを使うためのデフォルト穴あけルールを設定しています。
こちらは以下のサイトを参考に、設定しております。

[参考：Azure から外部へ通信を行うための許可 URL、IP アドレスまとめ](https://qiita.com/hisnakad/items/5a9f8157f62b959bc4be)

| カテゴリ | 種別 | 許可内容 |
|:---|:---|:---|
| **インフラストラクチャ** | Network | DNS (53), KMS (1688), Azure Monitor Agent, Machine Config (Arc) |
| **Microsoft 365** | Network | Exchange, SharePoint, Teams 等のサービスタグ |
| **プラットフォーム** | Application | Azure Portal, Entra ID, ARM, Front Door |
| **OS 更新** | Application | Windows Update, RHEL RHUI パッチ, Ubuntu パッケージ |
| **コンテナ** | Application | Defender for Containers, AKS FQDN Tag |
| **証明書** | Application | Amazon Trust (Office365 証明書チェーン) |

#### ルール管理の設計

Azure Firewall Policy は 3 階層でルールを管理します。

```
Firewall Policy
├── Rule Collection Group (RCG)     ← ルール種別で分離（Network / Application）
│   ├── Rule Collection (RC)        ← サブスクリプション単位で自動生成
│   │   └── Rule                    ← 個別の許可・拒否ルール
│   └── Rule Collection
└── Rule Collection Group
```

##### 分離方針：RCG はルール種別、RC はサブスクリプション単位

Terraform では **RCG が 1 つのリソース**（`azurerm_firewall_policy_rule_collection_group`）です。
RCG 内の RC はすべてインラインで定義されるため、1 つの RC を変更すると RCG 全体が更新対象になります。

ただし、RCG の更新は **Azure 側でアトミックに適用** されるため、**通信断は発生しません**。
既存のルールは新しいルールが反映されるまで有効です。Terraform 運用面の影響（apply 失敗の巻き添え、PR コンフリクト、Plan のノイズ）はありますが、通信への影響はありません。

RCG の上限は **50 / Policy** のため、Spoke ごとに RCG を作ると大規模環境では枯渇します。
本構成では **RCG をルール種別（Network / Application）で分離し、RC をサブスクリプション単位で自動生成** します。

##### RCG の全体構成

| RCG 名 | priority | 内容 |
|:---|:---|:---|
| `DefaultRuleCollectionGroup` | 200 | 全 Spoke 共通（DNS, KMS, Azure サービス等） |
| `SpokeNetworkRules` | 1000 | Spoke 固有の Network ルール（RC per サブスクリプション） |
| `SpokeApplicationRules` | 2000 | Spoke 固有の Application ルール（RC per サブスクリプション） |

```
DefaultRuleCollectionGroup (priority 200) — プラットフォーム管理・編集禁止
├── RC: AllowInfrastructure (DNS, KMS, AMA ...)
├── RC: AllowMicrosoft365
└── RC: AllowPlatformServices

SpokeNetworkRules (priority 1000) — YAML から自動生成
├── RC: my-system-network       ← subscriptions/my-system.yaml から
├── RC: other-system-network    ← subscriptions/other-system.yaml から
└── RC: ...

SpokeApplicationRules (priority 2000) — YAML から自動生成
├── RC: my-system-application   ← subscriptions/my-system.yaml から
├── RC: other-system-application ← subscriptions/other-system.yaml から
└── RC: ...
```

##### YAML でのルール定義

サブスクリプション YAML にファイアウォールルールを記述します。**Terraform コードの編集は不要** です。

```yaml
# subscriptions/my-system.yaml
display_name: "my-system"
subscription_id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
# ... VNet, alert_contacts 等は省略 ...

firewall_rules:
  network_rules:
    - name: AllowSQL
      protocols: [TCP]
      source_addresses: ["10.201.1.0/24"]
      destination_addresses: ["10.201.2.0/24"]
      destination_ports: ["1433"]

    - name: AllowRedis
      protocols: [TCP]
      source_addresses: ["10.201.1.0/24"]
      destination_addresses: ["10.201.3.0/24"]
      destination_ports: ["6380"]

  application_rules:
    - name: AllowExternalAPI
      source_addresses: ["10.201.1.0/24"]
      protocols:
        - type: Https
          port: 443
      destination_fqdns: ["api.example.com"]
```

この方式のメリット：

| 観点 | 効果 |
|:---|:---|
| **一元管理** | VNet、アラート、ファイアウォールルールがすべて 1 つの YAML に集約。Spoke の全貌を 1 ファイルで把握できる |
| **Terraform コード不変** | ルールの追加・変更は YAML の編集だけで完結。`.tf` ファイルの編集不要 |
| **レビューしやすい** | YAML のルール定義は HCL より読みやすく、非エンジニアでもレビュー可能 |
| **RCG 枯渇なし** | RCG は固定 3 つ。RC 上限 200 / RCG のため、サブスクリプション 200 個まで対応 |

> **運用ルール**: 運用チームは各サブスクリプションの YAML ファイルのみ編集し、PR レビューを経て main にマージします。

### Azure Bastion

Azure Bastion は、Azure Portal から VM に安全に RDP/SSH 接続するマネージドサービスです。VM にパブリック IP を付与せず、NSG で RDP/SSH ポートを開放する必要もありません。
Hub VNet の `AzureBastionSubnet` にデプロイされ、Hub およびピアリング済みの Spoke VNet 内の VM に接続できます。

[参考：Azure Bastion とは](https://learn.microsoft.com/ja-jp/azure/bastion/bastion-overview)

#### セッション録画

本構成では Bastion の SKU を **Standard** に設定し、**セッション録画（Session Recording）** を有効化しています。
VM への RDP/SSH 接続がすべて動画として自動録画され、監査・インシデント調査に活用できます。

| 設定 | 値 |
|:---|:---|
| **SKU** | Standard（`bastion_sku` 変数で制御、デフォルト: Standard） |
| **session_recording_enabled** | `true`（SKU が Basic 以外の場合に自動有効化） |
| **録画保存先** | `stbastionrec<location>`（Hub と同じリソースグループ） |
| **コンテナ** | `bastion-session-recordings` |

##### 録画の保存先設定（デプロイ後の手動設定が必要）

Terraform で Storage Account とコンテナは自動作成されますが、**Bastion と Storage Account を紐付ける SAS URL の設定**は Azure Portal で行う必要があります。

```
1. Azure Portal → Bastion リソース → 構成
2. 「セッション録画」セクションで Storage Account の SAS URL を設定
   - 対象コンテナ: bastion-session-recordings
   - 必要なアクセス許可: 読み取り, 書き込み, 一覧
   - 有効期限: 運用ポリシーに応じて設定（定期ローテーション推奨）
```

> **注意**: SAS URL には有効期限があるため、定期的なローテーションが必要です。

### Private DNS Resolver

Private DNS Resolver は、Azure VNet 内で DNS クエリを処理するマネージドサービスです。本構成では Hub VNet にデプロイし、以下の役割を担います。

| エンドポイント | 役割 |
|:---|:---|
| **インバウンド** | Spoke VNet やオンプレミスからの DNS クエリを受信し、Private DNS Zone で名前解決 |
| **アウトバウンド** | フォワーディングルールセットに基づき、外部 DNS へクエリを転送 |

Spoke VNet の DNS サーバーをインバウンドエンドポイントの IP に設定することで、全 Spoke から 一元的な名前解決の管理が可能になります。

```
Spoke VM → DNS Query: mystorageaccount.blob.core.windows.net
  → Spoke VNet DNS 設定: Resolver インバウンド IP
  → Private DNS Resolver
  → Private DNS Zone: privatelink.blob.core.windows.net
  → 解決先: 10.0.x.x（Private Endpoint のプライベート IP）
```

[参考：Azure Private DNS Resolver とは](https://learn.microsoft.com/ja-jp/azure/dns/dns-private-resolver-overview)

### Private DNS（56 ゾーン）

Private DNS ゾーンは、Azure PaaS サービスへの Private Endpoint 名前解決を行います。

```
例: ストレージアカウントに Private Endpoint を作成した場合

VM → DNS Query: mystorageaccount.blob.core.windows.net
  → Private DNS Zone: privatelink.blob.core.windows.net
  → 解決先: 10.0.x.x（Private Endpoint のプライベート IP）
  → インターネットを経由せずプライベート通信
```

56 ゾーンは主要な Azure サービス（Storage, SQL, Key Vault, Cosmos DB, Event Hub, Service Bus, Web Apps 等）をカバーしています。
Azureポリシーにより、PaaSリソースのプライベートエンドポイントの作成と同時にDNSレコードが自動で登録されます。
各ゾーンは Hub VNet にリンクされ、Hub VNet の DNS 設定を使う全 VNet から名前解決できます。

[参考：Private Link と DNS の大規模な統合](https://learn.microsoft.com/ja-jp/azure/cloud-adoption-framework/ready/azure-best-practices/private-link-and-dns-integration-at-scale)

---

## ポリシーシステム（3 層カスタマイズ）

Azure Policy は「このサブスクリプション内では〇〇を許可/禁止/監査/是正する」というルールを強制する仕組みです。
本構成では 3 層のポリシーライブラリを合成しています。

| Layer | ライブラリ | 説明 | URL |
| --- | --- | --- | --- |
| 1 | ALZ | MSが提供するAzure Landing Zoneの公式ポリシー群。ベストプラクティスに沿った300近くのポリシー割り当てを流用しています。| [ALZ](https://github.com/Azure/Azure-Landing-Zones-Library/tree/main/platform/alz) |
| 2 | AMBA | MSが提供するAzure Monitorのアラートを設定するための公式ポリシー群です。ベストプラクティスに沿ったアラート設定をAzureポリシーによって自動で実施することができます。 | [AMBA](https://github.com/Azure/Azure-Landing-Zones-Library/tree/main/platform/amba) |
| 3 | カスタム | 1,2層に加えて独自のカスタムポリシーやポリシー割り当てを定義することができます。 | なし |

![ポリシー 3 層アーキテクチャ](diagrams/readme-05-policy-3-layer.svg)

### alz ライブラリを使用する理由

alz ライブラリは外部依存が発生してしまいますが、それを上回るメリットがあります。

| 観点 | 自前で書いた場合の課題 | alz ライブラリで解決 |
|:---|:---|:---|
| **可読性** | Terraform の `azurerm_policy_*` リソースを数百個並べると、全体像の把握が困難 | アーキタイプ（YAML）で MG 単位のポリシー構成を宣言的に記述でき、見通しが良い |
| **実装コスト** | カスタムポリシー定義を 1 つずつ JSON で書く必要があり、数が多いと非現実的 | ALZ が提供する 300 近いポリシーをそのまま流用できる（ALZポリシーはカスタムポリシーも多く含まれる） |
| **柔軟性** | 組み込みポリシーだけでは MS のベストプラクティスを網羅できない | ALZポリシーをベースとして取捨選択しながら自社に合わせたポリシーを設計することができる |
| **保守性** | ポリシーの追加・変更のたびに `.tf` ファイルを直接編集する必要がある | `lib/` 内の YAML/JSON を編集するだけで完結し、`policy.tf` は原則ノータッチ |

AMBAについても選んだ理由があります。このREADMEの[監視基盤](#監視基盤)で解説しています。

### アーキタイプとは

「アーキタイプ」とは、**管理グループ 1 つ分のポリシーアーキテクチャ** のことです。
これにより、複雑になりがちなポリシーの定義、割り当ての管理をシンプルに表現することができます。

例えば `root` アーキタイプには：
- 約 160 個のポリシー定義
- 約 65 個のイニシアティブ
- 約 17 個のポリシー割り当て
- 5 個のロール定義

が含まれています。階層の上位に割り当てると、配下全体に継承されます。

### カスタマイズ方法（ブラックリスト方式）

`lib/archetype_definitions/` の YAML ファイルでポリシーの追加・除外を制御します。

```yaml
# 例: landing_zones_custom.yaml
name: landing_zones_custom
base_archetype: landing_zones    # ALZ 標準の landing_zones をベースに

# ↓ コメントを外すと、そのポリシーが除外される
policy_assignments_to_remove:
  - Enable-DDoS-VNET            # DDoS Protection は高額なので除外
  # - Deny-IP-forwarding        # ← これを外すと IP 転送禁止ポリシーも除外
  # - Deny-MgmtPorts-Internet   # ← 管理ポート(RDP/SSH)のインターネット公開禁止を除外
```

**デフォルトでは全ポリシーが有効** です。不要なものだけコメントを外して除外する「ブラックリスト方式」です。
各 YAML ファイルには、適用されている全ポリシーがコメントアウトされた状態で記載されているため、何が有効かを一目で確認できます。

### ポリシーデプロイの流れ

1. `alz` プロバイダーが 3 層のライブラリを読み込み、各 MG のポリシーセットを計算
2. `data "alz_architecture"` で全ポリシーの JSON 本体を取得
3. `locals` で 5 つのフラットマップに展開（定義、イニシアティブ、割り当て、ロール割り当て、ロール定義）
4. `azapi_resource` で Azure にデプロイ（定義 → イニシアティブ → 割り当て → ロール → ロール定義の順序）

**policy.tf は通常編集不要** です。ポリシーのカスタマイズは `lib/` 内のファイル編集だけで完結します。

### ポリシーデフォルト値

`data "alz_architecture"` の `policy_default_values` で、ポリシーパラメータの共通デフォルト値を一括設定しています。

```hcl
# policy.tf より抜粋（例）
policy_default_values = {
  # 全ポリシーの LAW 送信先を統一
  log_analytics_workspace_id   = azurerm_log_analytics_workspace.management.id
  # AMA エージェントの認証 ID
  user_assigned_managed_identity_id   = azurerm_user_assigned_identity.ama.id
  user_assigned_managed_identity_name = azurerm_user_assigned_identity.ama.name
  # AMBA アラートの通知先
  amba_alz_alert_email = var.amba_alert_email
}
```

これにより、数百のポリシー割り当てに個別に LAW ID を設定する必要がなくなります。

### MDFC Defender プラン構成

`Deploy-MDFC-Config-H224` ポリシー割り当ては、**Deploy-MDFC-Config** イニシアティブ（ポリシーセット定義）を使用して、Microsoft Defender for Cloud の全プランを一括構成します。

以下の Defender プランが含まれます:

ALZ ライブラリのデフォルトでは全プランが `Disabled` ですが、本リポジトリでは `policy.tf` の `policy_assignments_to_modify` で**全 12 プランを `DeployIfNotExists` にオーバーライド**しています。

| # | Defender プラン | パラメータ名 | 設定値 | 保護対象 |
|---|:---|:---|:---|:---|
| 1 | Defender for Servers | `enableAscForServers` | ✅ DeployIfNotExists | 仮想マシン（Windows/Linux） |
| 2 | Defender for Servers VA | `enableAscForServersVulnerabilityAssessments` | ✅ DeployIfNotExists | 脆弱性評価 |
| 3 | Defender for App Service | `enableAscForAppServices` | ✅ DeployIfNotExists | App Service / Functions |
| 4 | Defender for Azure SQL | `enableAscForSql` | ✅ DeployIfNotExists | Azure SQL Database |
| 5 | Defender for SQL on VMs | `enableAscForSqlOnVm` | ✅ DeployIfNotExists | SQL Server on VMs / Arc |
| 6 | Defender for Open-Source DB | `enableAscForOssDb` | ✅ DeployIfNotExists | PostgreSQL, MySQL, MariaDB |
| 7 | Defender for Cosmos DB | `enableAscForCosmosDbs` | ✅ DeployIfNotExists | Azure Cosmos DB |
| 8 | Defender for Storage | `enableAscForStorage` | ✅ DeployIfNotExists | Storage Account |
| 9 | Defender for Containers | `enableAscForContainers` | ✅ DeployIfNotExists | AKS / Kubernetes |
| 10 | Defender for Key Vault | `enableAscForKeyVault` | ✅ DeployIfNotExists | Key Vault |
| 11 | Defender for ARM | `enableAscForArm` | ✅ DeployIfNotExists | ARM 操作 |
| 12 | Defender CSPM | `enableAscForCspm` | ✅ DeployIfNotExists | Cloud Security Posture Management |

> **注**: ALZ ライブラリのデフォルトは `Disabled` です。個別に無効化したい場合は
> `policy.tf` の `policy_assignments_to_modify` から該当パラメータを削除してください。

### ガードレール・CMK 強制化

ALZ ライブラリのデフォルトでは、ガードレール系ポリシー（`Enforce-GR-*`）と CMK ポリシー（`Enforce-Encrypt-CMK0`）の `enforcementMode` は `DoNotEnforce`（監査のみ）に設定されています。これは段階的に有効化する運用を想定した設計です。

本リポジトリでは **全 28 ポリシーを `Default`（強制）モードに切り替え** ています。  
`policy.tf` の `guardrail_enforcement_overrides` で一括オーバーライドし、`policy_assignments_to_modify` で `platform` と `landingzones` の両管理グループに適用しています。

#### 対象ポリシー（28 件）

| カテゴリ | ポリシー割り当て名 | 備考 |
|:---|:---|:---|
| CMK | `Enforce-Encrypt-CMK0` | カスタマー マネージド キー強制 |
| API Management | `Enforce-GR-APIM0` | |
| App Services | `Enforce-GR-AppServices0` | |
| Automation | `Enforce-GR-Automation0` | |
| Bot Service | `Enforce-GR-BotService0` | |
| Cognitive Services | `Enforce-GR-CogServ0` | |
| Compute | `Enforce-GR-Compute0` | |
| Container Apps | `Enforce-GR-ContApps0` | |
| Container Instances | `Enforce-GR-ContInst0` | |
| Container Registry | `Enforce-GR-ContReg0` | |
| Cosmos DB | `Enforce-GR-CosmosDb0` | |
| Data Explorer | `Enforce-GR-DataExpl0` | |
| Data Factory | `Enforce-GR-DataFactory0` | |
| Event Grid | `Enforce-GR-EventGrid0` | |
| Event Hub | `Enforce-GR-EventHub0` | |
| Key Vault (Sup) | `Enforce-GR-KeyVaultSup0` | |
| Kubernetes | `Enforce-GR-Kubernetes0` | |
| Machine Learning | `Enforce-GR-MachLearn0` | |
| MySQL | `Enforce-GR-MySQL0` | |
| Network | `Enforce-GR-Network0` | DDoS Modify を `Disabled` に上書き |
| OpenAI | `Enforce-GR-OpenAI0` | |
| PostgreSQL | `Enforce-GR-PostgreSQL0` | |
| SQL | `Enforce-GR-SQL0` | |
| Service Bus | `Enforce-GR-ServiceBus0` | |
| Storage | `Enforce-GR-Storage0` | |
| Synapse | `Enforce-GR-Synapse0` | |
| Virtual Desktop | `Enforce-GR-VirtualDesk0` | |
| Subnet | `Enforce-Subnet-Private` | プライベートサブネット強制 |

#### DDoS Modify の無効化

`Enforce-GR-Network0` に含まれる DDoS Protection の Modify ポリシーは、DDoS Protection Plan が未契約の場合にコスト・運用上不要です。  
`vnetModifyDdos` パラメータを `Disabled` にオーバーライドし、DDoS 自動付与を無効化しています。  

#### ポリシー適用除外（Exemptions）

ガードレール強制化により、一部のリソースがポリシーに違反する場合があります。  
そのようなリソースには **ポリシー適用除外** を宣言的に管理します。

免除の定義場所は **2 箇所**あり、スコープによって使い分けます:

| 定義場所 | 対象スコープ | 用途 |
|:---|:---|:---|
| `lib/policy_exemptions/*.yaml` | MG・基盤リソース（クロスサブスクリプション） | Terraform state SA など、基盤コンポーネントの免除 |
| `subscriptions/<name>.yaml` の `policy_exemptions` | そのサブスクリプション配下のリソース | Spoke サブスクリプション個別の免除 |

> **使い分けの指針**: 管理グループレベルの免除や複数サブスクリプションにまたがる免除は `lib/policy_exemptions/` に、  
> 特定サブスクリプション配下のリソース免除はそのサブスクリプションの YAML ファイルに記載してください。

Azure Policy の免除は**スコープ**を指定して、そのスコープ配下のリソースに対するポリシー適用を除外する仕組みです。

| スコープレベル | 例 | 影響範囲 |
|:---|:---|:---|
| 管理グループ | `/providers/Microsoft.Management/managementGroups/alz-platform` | MG 配下の全リソース |
| サブスクリプション | `/subscriptions/bec80a1b-...` | サブスクリプション内の全リソース |
| リソースグループ | `/subscriptions/.../resourceGroups/rg-terraform-state` | RG 内の全リソース |
| リソース | `/subscriptions/.../providers/Microsoft.Storage/storageAccounts/stterraform...` | そのリソースのみ |

> `azapi_resource` を使用しているため、**任意のサブスクリプション**（基盤・Spoke 問わず）の**全スコープレベル**に対応しています。

##### 方法 A: グローバル免除（`lib/policy_exemptions/`）

基盤リソースや MG レベルの免除は `lib/policy_exemptions/` に配置します:

```
lib/policy_exemptions/
  exemptions.yaml                                 # グローバルポリシー適用除外
```

**例 1: イニシアティブ全体を免除**（state SA を Storage ガードレール全体から免除）

```yaml
# lib/policy_exemptions/exemptions.yaml

exemptions:
  - name: exempt-state-sa-storage-gr
    policy_assignment: Enforce-GR-Storage0     # イニシアティブの割り当て名
    management_group_suffix: platform          # 割り当て元 MG（${root_id}-platform）
    scope: ${terraform_state_storage_account_id}  # 免除スコープ（リソース ID）
    category: Waiver
    display_name: "Terraform state SA — Storage ガードレール免除"
    description: >-
      State backend は GitHub Actions OIDC 経由で管理。
      SharedKey 制限・パブリックアクセス制御は Azure Portal で個別設定済み。
```

**例 2: イニシアティブ内の特定ポリシーだけ免除**（SharedKey 禁止とパブリックエンドポイント制御のみ）

```yaml
exemptions:
  - name: exempt-state-sa-storage-partial
    policy_assignment: Enforce-GR-Storage0
    management_group_suffix: platform
    scope: ${terraform_state_storage_account_id}
    category: Waiver
    display_name: "Terraform state SA — SharedKey/PublicEndpoint のみ免除"
    description: "SharedKey とパブリックエンドポイント制御のみ免除。他のポリシーは適用"
    policy_definition_reference_ids:           # イニシアティブ内の特定ポリシーだけ免除
      - Deny-Storage-Shared-Key                # SharedKey Deny
      - Modify-Storage-Account-PublicEndpoint   # パブリックエンドポイント Modify
      - Modify-Blob-Storage-Account-PublicEndpoint
```

> **ヒント**: `policy_definition_reference_ids` を省略するとイニシアティブ全体が免除されます。  
> 特定ポリシーのみ免除したい場合は `policyDefinitionReferenceId` を指定してください。  
> 各イニシアティブの参照 ID は YAML ファイル内のコメントに一覧を記載しています。

##### 方法 B: サブスクリプション YAML 免除（`subscriptions/<name>.yaml`）

サブスクリプション配下のリソースに対する免除は、そのサブスクリプションの YAML ファイルに直接記載できます。  
`${subscription_id}` プレースホルダーが自動的にサブスクリプション ID に解決されます。

**例: サブスクリプション内の特定リソースを免除**

```yaml
# subscriptions/test-subscription.yaml （抜粋）

policy_exemptions:
  - name: exempt-my-app-storage
    policy_assignment: Enforce-GR-Storage0       # 免除するポリシー割り当て名
    scope: ${subscription_id}/resourceGroups/rg-my-app/providers/Microsoft.Storage/storageAccounts/stmyapp
    category: Waiver
    display_name: "My App SA — Storage ガードレール免除"
    description: "レガシーアプリが SharedKey を必要とするため免除"
    policy_definition_reference_ids:             # 省略可（省略 = イニシアティブ全体を免除）
      - Deny-Storage-Shared-Key
```

**例: サブスクリプション全体を免除**

```yaml
policy_exemptions:
  - name: exempt-test-sub-keyvault
    policy_assignment: Enforce-GR-KeyVault0
    scope: ${subscription_id}                     # サブスクリプション全体
    category: Mitigated
    display_name: "テスト環境 — KeyVault ガードレール免除"
    description: "テスト環境のため KeyVault ガードレールを一時免除"
```

> **ポイント**: `management_group_suffix` は省略可能です。省略した場合、サブスクリプションの  
> `management_group_id`（corp → landingzones、management → platform 等）から自動推定されます。  
> 明示的に指定することも可能です。

##### フィールドリファレンス

| フィールド | グローバル | サブスク YAML | 説明 |
|:---|:---:|:---:|:---|
| `name` | ✅ | ✅ | Azure 上の免除リソース名（64 文字以内、英数字とハイフン） |
| `policy_assignment` | ✅ | ✅ | 免除対象のポリシー割り当て名（例: `Enforce-GR-Storage0`） |
| `management_group_suffix` | ✅ | 自動推定 | ポリシーが割り当てられている MG のサフィックス（`${root_id}-{suffix}` の `{suffix}` 部分）。サブスク YAML では `management_group_id` から自動推定（省略可） |
| `scope` | ✅ | ✅ | 免除スコープ。グローバル: `${変数名}` で変数参照。サブスク YAML: `${subscription_id}` でサブスク ID に自動変換 |
| `category` | ✅ | ✅ | `Waiver`（恒久的免除）または `Mitigated`（代替措置により免除） |
| `display_name` | ✅ | ✅ | Azure Portal に表示される免除の名前 |
| `description` | ✅ | ✅ | 免除理由の説明（監査・レビュー用） |
| `policy_definition_reference_ids` | — | — | イニシアティブ内の特定ポリシーだけ免除する場合に指定（省略 = 全体免除） |

##### 動作の仕組み

1. `policy-exemptions.tf` が 2 つのソースから免除を収集:
   - **グローバル**: `lib/policy_exemptions/*.yaml` を自動検出・読み込み、`scope` 内の `${変数名}` を変数値で解決
   - **サブスクリプション**: `subscriptions/*.yaml` の `policy_exemptions` セクションを読み込み、`${subscription_id}` を実際の ID に解決し、`management_group_suffix` を所属 MG から自動推定
2. 両ソースの免除を統合（`merge`）し、重複キーはサブスクリプション YAML が優先
3. スコープが空文字の免除はスキップ（リソース未作成・サブスク未解決）
4. `azapi_resource` で Azure にデプロイ
5. `policy_definition_reference_ids` が指定されていれば、イニシアティブ内の特定ポリシーのみ免除

##### 免除を追加する手順

**基盤リソース・MG レベルの免除:**

1. `lib/policy_exemptions/` に新しい YAML ファイルを作成（または既存ファイルに追記）
2. スコープにリソース ID を直接記入、または `${変数名}` で変数参照
3. 変数参照の場合は `variables.tf` に変数を追加し、`terraform.tfvars` で値を設定

**サブスクリプション配下のリソース免除:**

1. 対象サブスクリプションの YAML ファイル（`subscriptions/<name>.yaml`）を開く
2. `policy_exemptions:` セクションを追加し、免除を記載
3. スコープに `${subscription_id}` を使うとサブスクリプション ID が自動解決される
4. `management_group_suffix` は通常省略可（所属 MG から自動推定）

**共通:**

- イニシアティブ内の特定ポリシーだけ免除する場合は `policy_definition_reference_ids` を指定
- `terraform plan` で免除リソースの作成を確認

---

## サブスクリプション自動払い出し（Vending）

### 概要

新しいサブスクリプション（= ワークロード環境）を追加するとき、YAML ファイルを 1 つ置くだけで **サブスクリプションの作成から** ネットワーク・監視リソースまですべて自動で構成されます。
以下のドキュメントを参考に実装しています。

[参考：サブスクリプションの自動販売の実装ガイダンス](https://learn.microsoft.com/ja-jp/azure/architecture/landing-zones/subscription-vending)

### 手順
例として、bashスクリプトでサブスクリプションを払い出してみます。

```bash
# 1. テンプレートをコピー
cp subscriptions/templates/corp-template.yaml subscriptions/my-system.yaml

# 2. YAML を編集（表示名、IP 範囲等を記入）
#    subscription_id は省略 → 新規作成されます
#    既存サブスクリプションを使う場合は subscription_id を記入
vim subscriptions/my-system.yaml

# 3. デプロイ
terraform plan    # 何が作られるか確認
terraform apply   # 実際に作成
```

**Terraform コードの編集は一切不要です。** YAML を追加するだけで以下が自動作成されます。

### サブスクリプションの作成と既存利用

YAML の `subscription_id` フィールドで動作が切り替わります。

| `subscription_id` | 動作 | 前提条件 |
|:---|:---|:---|
| **省略**（推奨） | `azurerm_subscription` でサブスクリプションを新規作成 | `billing_scope_id` 変数が必須 |
| **指定** | 既存のサブスクリプションをそのまま使用 | なし |

新規作成時は以下が自動的に行われます：
1. サブスクリプション作成（エイリアス: `${root_id}-${YAML ファイル名}`）
2. 管理グループへの配置（`management_group_id` に基づく）
3. API 伝搬待機（30 秒）
4. ネットワーク・監視リソースの構成

#### billing_scope_id の設定（EA / MCA）

サブスクリプションを新規作成するには、Azure の課金スコープ ID が必要です。
契約形態（EA / MCA）によってフォーマットが異なります。

| 契約形態 | フォーマット |
|:---|:---|
| **EA** (Enterprise Agreement) | `/providers/Microsoft.Billing/billingAccounts/{billingAccountName}/enrollmentAccounts/{enrollmentAccountName}` |
| **MCA** (Microsoft Customer Agreement) | `/providers/Microsoft.Billing/billingAccounts/{billingAccountName}/billingProfiles/{billingProfileName}/invoiceSections/{invoiceSectionName}` |

```hcl
# terraform.tfvars に追記
billing_scope_id = "/providers/Microsoft.Billing/billingAccounts/1234567890/enrollmentAccounts/0123456"  # EA の例
```

> **billing_scope_id の確認方法**: Azure Portal → [コストの管理と請求] → [課金スコープ] → [請求書セクション] → [プロパティ]から確認できます。
> または `az billing account list` / `az billing enrollment-account list` コマンドでも取得できます。

#### 必要な権限
Terraformデプロイ用のマネージドIDに以下の権限が必要です。

| 契約形態 | 必要なロール |
|:---|:---|
| EA | Enrollment Account の **Owner** |
| MCA | Invoice Section の **Contributor** または Billing Profile の **Contributor** |

#### 安全性の設計

| 対策 | 説明 |
|:---|:---|
| **`prevent_cancellation_on_destroy = true`** | `terraform destroy` 時にサブスクリプションが誤ってキャンセルされるのを防止 |
| **API 伝搬待機（30 秒）** | サブスクリプション作成直後に後続リソースを作ろうとすると API エラーが発生するため、`time_sleep` で待機 |
| **エイリアス命名規則** | `${root_id}-${YAML ファイル名}` で一意性を保証（例: `alz-my-system`） |

### 自動作成されるリソース

![Subscription Vending 自動生成リソース](diagrams/readme-06-vending-resources.svg)

### Spoke リソースの委任とプラットフォーム管理

Spoke サブスクリプション内のリソースは、**Spoke チームに委任するもの**と**プラットフォームが継続管理するもの**に分離されています。

| 区分 | リソース | Terraform の動作 | 理由 |
|:---|:---|:---|:---|
| **委任（ignore_changes = all）** | RG, VNet(本体), Subnet, NSG, AG, ARP | 初回作成のみ | Spoke チームが自由に変更可能 |
| **プラットフォーム管理** | VNet DNS, Route Table, Peering, GW Route | 継続追跡 | DR 切替・セキュリティ保護 |

#### なぜルートテーブルと DNS をプラットフォーム管理するのか

- **Route Table**: `ignore_changes = all` にすると、Spoke チームが独自ルートを追加して Firewall をバイパスできてしまう。また DR 切替時にデフォルトルートの next hop IP をセカンダリ Firewall に更新する必要がある
- **VNet DNS**: VNet 本体は `ignore_changes = all` で委任しつつ、DNS サーバー設定だけを `azapi_update_resource`（PATCH）で継続管理。DR 切替時にセカンダリ Hub の DNS Resolver に自動更新される

#### Spoke チームの自由度

- **自由に変更可能**: VNet アドレス空間、NSG ルール、AG/ARP 設定
- **Terraform が保護**: デフォルトルート（FW 向け）、DNS サーバー、Hub 接続（Peering）
- **Azure 上で削除された場合**: Terraform がベースラインを再作成（インフラの一貫性を保証）

### YAML の書き方

```yaml
# subscriptions/my-system.yaml
display_name: "my-system"
# subscription_id: "xxx..."             # 省略 → 新規作成、指定 → 既存利用
workload_type: "Production"
management_group_id: "corp"          # corp または online
location: "japaneast"

tags:
  environment: "production"
  cost_center: "CC-1234"
  owner: "platform-team"
  system_name: "my-system"

resource_groups:
  network:
    name: "rg-my-system-network"
    location: "japaneast"
  application:
    name: "rg-my-system-app"
    location: "japaneast"

alert_contacts:                       # Spoke アラートの通知先（任意）
  - name: "システム管理者"
    email_address: "admin@example.com"
  - name: "オンコール担当"
    email_address: "oncall@example.com"

virtual_network:
  name: "vnet-my-system"
  resource_group_name: "rg-my-system-network"
  address_space: ["10.201.0.0/16"]
  hub_peering_enabled: true           # Hub VNet とピアリング
  use_hub_gateway: true               # Corp = true, Online = false
  subnets:
    - name: "snet-app"
      address_prefix: "10.201.1.0/24"
    - name: "snet-data"
      address_prefix: "10.201.2.0/24"
```

### Corp と Online の違い

| 設定 | Corp | Online |
|:---|:---|:---|
| `management_group_id` | `corp` | `online` |
| `use_hub_gateway` | `true` | `false` |
| オンプレ接続 | あり（ER Gateway 経由） | なし |
| 適用されるポリシー | 社内向けセキュリティ | インターネット公開向け |

### サブスクリプション Vending のトラブルシューティング

#### エイリアス競合（Alias already exists）

サブスクリプションを一度作成した後、State から削除して再作成しようとするとエイリアス競合エラーが発生します。

```
│ Error: creating Subscription (Alias "alz-my-system"): unexpected status 409 (409 Conflict)
```

**対処法**: YAML に `subscription_id` を記載して既存利用モードに切り替えてください。

```yaml
# subscriptions/my-system.yaml
subscription_id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # ← 作成済みサブスクリプションの ID を記載
```

これにより `azurerm_subscription` での新規作成をスキップし、既存サブスクリプションをそのまま利用します。

---

## 監視基盤

Management サブスクリプションに監視の中核リソースを集約しています。

### リソース一覧

| リソース | 用途 |
|:---|:---|
| **Log Analytics Workspace (LAW)** | 全 Azure リソースのログ・メトリクスを集約する中央データストア |
| **Microsoft Sentinel** | LAW 上で動作する SIEM/SOAR。セキュリティイベントの自動検出・アラート |
| **UAMI: AMA** | Azure Monitor Agent がログ収集する際の認証 ID |
| **UAMI: AMBA** | AMBA アラートが操作する際の認証 ID |
| **DCR: VM Insights** | VM のパフォーマンスデータ（CPU, Memory, Disk, Network）を LAW に収集 |
| **DCR: Change Tracking** | Windows レジストリ/ファイル/サービスの変更検出結果を LAW に収集 |
| **DCR: Defender for SQL** | SQL 脆弱性アラート/ログイン/テレメトリを LAW に収集 |
| **Change Tracking Solution** | Change Tracking 機能の有効化（Legacy Solution） |
| **Storage Account（LAW アーカイブ）** | LAW ログの長期アーカイブ先（GRS、Hot → Archive tier、不変性有効） |
| **Data Export Rule** | LAW の指定テーブルを Blob Storage に自動エクスポート |

### Log Analytics Workspace（LAW）— ログを一か所に集める

LAW は、全 Azure リソースのログ・メトリクスを **一か所に集約する中央データストア** です。

[参考：Azure Monitor ログの概要](https://learn.microsoft.com/ja-jp/azure/azure-monitor/logs/data-platform-logs)

Enterprise 環境では数十のサブスクリプション、数百のリソースが常に動いています。ログがバラバラに存在すると、以下の問題が発生します。

| 課題 | LAW 集約で解決 |
|:---|:---|
| **障害調査** — 複数サブスクリプションを個別にログ検索する必要がある | KQL 1 つで全環境のログを横断検索できる |
| **セキュリティ** — 不審なサインインを見つけるのにテナント全体を見渡せない | Sentinel が LAW 上で全サインインログを自動分析・アラート |
| **コンプライアンス** — 監査証跡がリソースごとに散在 | LAW にすべてのアクティビティログが残り、保持ポリシーを一括管理 |
| **コスト可視化** — どのリソースがどのくらいログを出しているかわからない | LAW の使用量分析でデータ量をリソース別に把握 |
| **自動化** — ログベースのアクションを組みにくい | アラートルールで閾値超過時に自動通知・自動修復 |

本構成では、Azure Policy により **全サブスクリプションのリソースが自動的にこの LAW にログを送信** するよう強制されています。手動設定は不要です。

#### LAW ログアーカイブ（Blob Storage）

LAW のログを長期保存・監査対応するため、Blob Storage へのアーカイブ機能を提供しています。
`law_archive_retention_days` に保持日数を指定すると有効化されます（0 = アーカイブ無効）。

##### tfvars での設定

```hcl
# terraform.tfvars
log_analytics_retention_days = 30    # LAW 上のデータ保持（分析用・短期）
law_archive_retention_days   = 365   # Blob アーカイブの保持日数（0 = 無効）

# エクスポートテーブルをカスタマイズする場合（省略時はデフォルト値を使用）
# law_archive_export_tables = ["SecurityEvent", "AzureActivity", "Syslog"]
```

| 変数 | 説明 | デフォルト |
|:---|:---|:---|
| `log_analytics_retention_days` | LAW 内のデータ保持日数（30〜730） | 30 |
| `law_archive_retention_days` | Blob アーカイブの保持日数。0 = 無効 | 0 |
| `law_archive_export_tables` | エクスポートするテーブル名のリスト | 全 34 テーブル |

##### アーキテクチャ

```
LAW (Management Sub)
  │
  ├── Data Export Rule (テーブル単位・ニアリアルタイム)
  │
  ▼
Storage Account (stlawarchive<region>)
  ├── Access tier: Hot（→ Archive 即移行で早期削除ペナルティ回避）
  ├── Immutability policy: Terraform で自動設定（Unlocked 状態）
  └── Container: "am-law-archive"
      ├── Lifecycle Policy: 即座に Archive tier へ移行（※）
      ├── Blob versioning: 有効
      └── Blob soft delete: 30日
```

> ※ Azure のライフサイクルポリシーは 1 日 1 回実行のため、Blob 作成後 ~24 時間以内に Archive tier に移行します。アカウントの access tier を Hot に設定しているのは、Cool（30日）や Cold（90日）と異なり **Hot tier には最低保持期間がなく、即時移動でも早期削除ペナルティが発生しない** ためです。

##### リソース一覧

| リソース | 説明 |
|:---|:---|
| **Storage Account** | GRS（geo 冗長）、Hot tier、TLS 1.2、不変性有効、パブリックアクセス無効 |
| **Container** | `am-law-archive` — エクスポート先 |
| **Lifecycle Policy** | 作成後即座に Archive tier へ移行（コスト最小化） |
| **Data Export Rule** | LAW の指定テーブルを自動エクスポート |

##### エクスポート対象テーブル（デフォルト）

`var.law_archive_export_tables` で変更可能です。全 34 テーブル。

| カテゴリ | テーブル | 内容 |
|:---|:---|:---|
| **セキュリティ** | `SecurityEvent` | Windows セキュリティイベント（ログオン、権限変更等） |
| | `SecurityAlert` | Defender 各種アラート |
| | `SecurityIncident` | セキュリティインシデント（Sentinel） |
| | `CommonSecurityLog` | CEF 形式のセキュリティログ |
| **Entra ID** | `SigninLogs` | 対話型サインインログ |
| | `AADNonInteractiveUserSignInLogs` | 非対話型サインイン |
| | `AADServicePrincipalSignInLogs` | サービスプリンシパルのサインイン |
| | `AADManagedIdentitySignInLogs` | マネージド ID のサインイン |
| | `AuditLogs` | ユーザー・グループ変更等の監査ログ |
| | `AADProvisioningLogs` | アプリ・HR プロビジョニングログ |
| **監査** | `AzureActivity` | Azure 管理操作の全監査ログ |
| | `ConfigurationChange` | OS 構成変更の検出 |
| | `ConfigurationData` | OS 構成ベースライン |
| **Azure Firewall** | `AZFWNetworkRule` | ネットワークルール処理（許可/拒否） |
| | `AZFWApplicationRule` | アプリケーションルール処理（FQDN ベース） |
| | `AZFWNatRule` | NAT/DNAT ルール処理 |
| | `AZFWThreatIntel` | 脅威インテリジェンスによるブロック |
| | `AZFWIdpsSignature` | IDPS（侵入検知・防止）検出 |
| | `AZFWDnsQuery` | DNS プロキシクエリログ |
| **DNS** | `DnsEvents` | DNS クエリ・応答イベント |
| | `DnsInventory` | DNS サーバーインベントリ |
| **監視** | `Heartbeat` | エージェント死活監視 |
| | `Perf` | VM パフォーマンスカウンター |
| | `InsightsMetrics` | VM Insights メトリクス |
| | `VMConnection` | VM 間ネットワーク接続データ |
| | `Event` | Windows イベントログ |
| | `Syslog` | Linux syslog |
| | `W3CIISLog` | IIS アクセスログ |
| **更新管理** | `Update` | 利用可能な更新プログラム |
| | `UpdateSummary` | パッチコンプライアンス状況 |
| **Azure 診断** | `AzureDiagnostics` | リソース診断ログ（NSG, Key Vault, SQL 等） |
| | `AzureMetrics` | リソースメトリクス |
| **Defender** | `ProtectionStatus` | マルウェア対策の状態 |
| | `ThreatIntelligenceIndicator` | 脅威インテリジェンス IOC |

##### 不変ポリシー（WORM）

Terraform が Storage Account 作成時にバージョンレベルの不変ポリシーを自動設定します。

| 設定 | 値 | 説明 |
|:---|:---|:---|
| `state` | `Unlocked` | ポリシーの延長・削除が可能な状態（Terraform 管理用） |
| `period_since_creation_in_days` | `law_archive_retention_days` の値 | Blob 作成後の保護期間 |
| `allow_protected_append_writes` | `true` | Data Export による追記を許可 |

> **本番運用でのロック**: コンプライアンス要件で削除不可を厳密に保証する場合は、Terraform デプロイ後に Azure Portal でポリシーを **Locked** に変更してください。ロック後は保持期間の短縮・ポリシーの削除が不可能になります。

> **`terraform destroy` 時の注意**: バージョンレベル不変性が有効な Storage Account は `AccountProtectedFromDeletion` により **Unlocked 状態でも `terraform destroy` 単体では削除できません**。CD ワークフローの Destroy ジョブには Pre-Destroy Cleanup ステップが組み込まれており自動処理されます。
> Locked 状態の場合はポリシー保持期間が経過するまで削除不可のため、Azure Portal でポリシーを先に解除してください。

##### アーカイブデータの分析

Archive tier のデータは直接読み取れません。分析が必要な場合：

1. Azure Portal で対象 Blob を **リハイドレート**（Archive → Hot/Cool に復元、Standard 優先度で最大 15 時間）
2. LAW に再取り込み、または Azure Data Explorer の外部テーブルとして KQL でクエリ

### AMBA（Azure Monitor Baseline Alerts）— ベストプラクティスのアラートを自動設定

[参考：Azure Monitor Baseline Alerts](https://azure.github.io/azure-monitor-baseline-alerts/)

AMBA は Microsoft が公式に提供する **Azure 監視のベースラインアラート集** です。
「このリソースには、このメトリクスで、この閾値のアラートを設定すべき」というベストプラクティスが、Azure Policy の形でパッケージ化されています。

#### AMBA が解決する課題

アラート設定は手動で行うと非常に大変です。

- VM の CPU 使用率、メモリ使用率、ディスク I/O
- ストレージの可用性、レイテンシ
- SQL のデッドロック、DTU 使用率
- Key Vault の期限切れ証明書
- ExpressRoute の BGP ピア状態、回線利用率
- 全てのサブスクリプションのサービス正常性
- ...

こうしたメトリクスごとに適切な閾値とアクションを個別で定義するのは、規模が大きくなるほど非現実的です。
AMBA はこれらを **ポリシーとして一括デプロイ** します。新しいリソースが作成されると、ポリシーにより自動的にアラートルールが設定されます。

#### 本構成での AMBA

| 設定 | 説明 |
|:---|:---|
| **ポリシーライブラリ** | `platform/amba`（policy.tf の `library_references` で参照） |
| **適用範囲** | 管理グループ階層全体（Root, Platform, LZ 等に各種アラートポリシーを割り当て） |
| **通知先（基盤）** | `var.amba_alert_email` で指定したメールアドレスに通知 |
| **通知先（Spoke）** | YAML の `alert_contacts` で指定した担当者に通知 |
| **認証** | UAMI: AMBA（アラートアクションの実行に使用） |

#### Spoke サブスクリプション別アラートルーティング

基盤サブスクリプション（Management, Connectivity, Identity, Security）は全社共通のメールアドレスに通知しますが、Spoke サブスクリプションのアラートは **そのサブスクリプションの担当者** に直接通知されます。

この仕組みは YAML の `alert_contacts` フィールドで制御されます。サブスクリプション払い出し YAML にメールアドレスを記載するだけで、以下が自動作成されます。

| リソース | 説明 |
|:---|:---|
| **リソースグループ** | Spoke サブスクリプション内に `rg-amba-alerts-<location>` を作成 |
| **Action Group** | `alert_contacts` のメールアドレスを通知先として登録。Spoke サブスクリプション内に配置 |
| **Alert Processing Rule** | スコープ = Spoke サブスクリプション全体。同一サブスクリプション内の AG にルーティング |

```yaml
# subscriptions/my-system.yaml に追記するだけ
alert_contacts:
  - name: "システム管理者"
    email_address: "admin@example.com"
  - name: "オンコール担当"
    email_address: "oncall@example.com"
```

`alert_contacts` を定義しない場合、AMBA デフォルトの通知先（`amba_alert_email`）が使用されます。

### DCR（Data Collection Rule）とは

DCR は「どのデータを、どこに、どのくらいの頻度で送るか」を定義するルールです。
VM にエージェント (AMA) をインストールすると、DCR に従ってデータが自動収集されます。

```
VM 上の AMA エージェント
  → DCR（収集ルール）に従い
  → LAW（Log Analytics Workspace）にデータ送信
  → Sentinel / アラートルールが検知・通知
```

---

## セキュリティ & ガバナンス

本章では、ポリシーのコンプライアンス運用、Microsoft Defender for Cloud、Microsoft Sentinel の構成について説明します。

### ポリシーコンプライアンス運用

Azure Policy の効果（Effect）によって、非準拠リソースへの対処方法が異なります。

| 効果 | 新規リソース | 既存リソース | 対処方法 |
|:---|:---|:---|:---|
| **DeployIfNotExists (DINE)** | 自動適用 | 修復タスクが必要 | Policy Remediation ワークフロー（手動実行） |
| **Modify** | 自動適用 | 修復タスクが必要 | 同上 |
| **Deny** | 作成をブロック | — | 該当なし（既存リソースには影響しない） |
| **Audit** | 非準拠を記録 | 非準拠を記録 | コード修正 or 適用除外 |
| **AuditIfNotExists** | 非準拠を記録 | 非準拠を記録 | 同上 |

#### DINE / Modify ポリシーの修復

DINE / Modify ポリシーは**新規リソースには自動適用**されますが、**割り当て前に作成された既存リソースには修復タスク（Remediation Task）が必要**です。

本構成では GitHub Actions の **Policy Remediation ワークフロー**（手動実行）で一括対応します。

```
手動実行（workflow_dispatch）
  → 管理グループ階層を再帰スキャン
  → identity を持つ割り当て（= DINE/Modify）を収集
  → イニシアティブ: メンバーポリシーごとに修復タスクを作成
  → 単一ポリシー: 直接修復タスクを作成
```

**実行タイミング:**

| タイミング | 理由 |
|:---|:---|
| 初回デプロイ後 | 既存リソースに DINE / Modify を適用 |
| ポリシーライブラリ更新後 | 新しい DINE ポリシーが追加された場合 |
| 新しい DINE ポリシーを追加した後 | カスタムポリシーの既存リソースへの適用 |

> **注意**: 新規リソースは自動的にポリシーが適用されるため、日常的な実行は不要です。

#### Audit ポリシーの非準拠対応

Audit ポリシーはリソースの作成・変更をブロックしません。非準拠を**記録するのみ**です。
Azure Portal の「ポリシー準拠」ダッシュボードで非準拠リソースを確認し、以下の方針で対処します。

| 非準拠の原因 | 対処 |
|:---|:---|
| **設計上の意図的な設定** | 適用除外（Exemption）を宣言（[ポリシー適用除外](#ポリシー適用除外exemptions)参照） |
| **修正すべき設定** | Terraform コードを修正して PR → マージ → CD apply |
| **評価タイミングの遅延** | ポリシー再評価を待つ（約 24 時間周期）または手動トリガー |

> **手動でのポリシー再評価**: `az policy state trigger-scan --subscription "<SUBSCRIPTION_ID>" --no-wait` で即座にスキャンを開始できます。結果の反映には数分〜数十分かかります。


### Microsoft Defender for Cloud

本構成では `Deploy-MDFC-Config-H224` ポリシー割り当てにより、Microsoft Defender for Cloud の**全 12 プラン**を一括有効化しています。

| # | プラン | 保護対象 |
|:---:|:---|:---|
| 1 | Servers | VM（Windows / Linux） |
| 2 | Servers VA | 脆弱性評価 |
| 3 | App Service | App Service / Functions |
| 4 | Azure SQL | SQL Database |
| 5 | SQL on VMs | SQL Server on VMs / Arc |
| 6 | Open-Source DB | PostgreSQL / MySQL / MariaDB |
| 7 | Cosmos DB | Azure Cosmos DB |
| 8 | Storage | Storage Account |
| 9 | Containers | AKS / Kubernetes |
| 10 | Key Vault | Key Vault |
| 11 | ARM | ARM 操作 |
| 12 | CSPM | クラウドセキュリティ態勢管理 |

#### 動作の仕組み

```
DINE ポリシー（Deploy-MDFC-Config-H224）
  → 各サブスクリプションで Defender プランを自動有効化
  → セキュリティ連絡先メールを自動設定
  → 新規サブスクリプション追加時も自動適用（MG 継承）
```

- **新規サブスクリプション**: MG に配置された時点で DINE ポリシーが自動で Defender を有効化
- **既存サブスクリプション**: Policy Remediation ワークフロー実行で有効化
- **セキュリティ連絡先**: `policy_default_values` の `email_security_contact` で一括設定

#### Defender アラートの確認

Defender for Cloud のアラートは以下の場所で確認できます:

| 確認場所 | 用途 |
|:---|:---|
| **Azure Portal → Defender for Cloud → セキュリティ アラート** | すべてのアラート一覧 |
| **Azure Portal → Defender for Cloud → 推奨事項** | セキュリティ態勢の改善提案 |
| **セキュリティ連絡先メール** | 高重大度アラートの自動通知 |
| **Log Analytics Workspace** | SecurityAlert テーブルでログ分析 |
| **Microsoft Sentinel** | 高度な脅威検知・インシデント管理（後述） |

### Microsoft Sentinel（SIEM / SOAR）

本構成では Microsoft Sentinel を LAW 上にオンボードし、**セキュリティイベントの自動検出・調査・対応**を一元化しています。

#### Terraform リソース

```hcl
# management-resources.tf
resource "azapi_resource" "sentinel" {
  count     = var.sentinel_enabled ? 1 : 0
  type      = "Microsoft.SecurityInsights/onboardingStates@2024-03-01"
  name      = "default"
  parent_id = azurerm_log_analytics_workspace.main.id
}
```

| 設定 | 値 |
|:---|:---|
| **有効化フラグ** | `var.sentinel_enabled`（デフォルト: `true`） |
| **親リソース** | Log Analytics Workspace（Management サブスクリプション） |
| **プロバイダー** | azapi（PUT は冪等、再デプロイ安全） |

#### Sentinel の役割

Defender for Cloud が**各リソースの脅威を検出してアラートを生成**するのに対し、Sentinel は**組織全体のセキュリティイベントを横断的に分析・対応**する SIEM/SOAR プラットフォームです。

```
各種ログソース
  ├── Defender for Cloud → SecurityAlert テーブル
  ├── Entra ID → SigninLogs / AuditLogs
  ├── Azure Firewall → AZFW* テーブル
  ├── Azure Activity → AzureActivity
  └── VM / OS ログ → SecurityEvent / Syslog
        │
        ▼
  Log Analytics Workspace（中央集約）
        │
        ▼
  Microsoft Sentinel
  ├── 分析ルール: 相関分析・異常検知 → インシデント自動生成
  ├── ハンティング: KQL でプロアクティブに脅威を探索
  ├── ワークブック: セキュリティダッシュボード
  └── オートメーション: ロジックアプリ / プレイブックで自動対応
```

#### Defender for Cloud との連携

| コンポーネント | 役割 | データの流れ |
|:---|:---|:---|
| **Defender for Cloud** | リソース単位の脅威検出・推奨事項 | アラートを `SecurityAlert` テーブルに書き込み |
| **Sentinel** | 組織横断の相関分析・インシデント管理 | `SecurityAlert` を取り込み、分析ルールでインシデント化 |

Defender が検出した個別アラートを Sentinel が**相関分析**し、複数のアラートを 1 つのインシデントにまとめることで、攻撃チェーン全体を可視化します。

#### 主要なデータテーブル

Sentinel が分析に使用する主なテーブル（LAW に自動収集済み）:

| テーブル | 内容 |
|:---|:---|
| `SecurityAlert` | Defender 各種アラート |
| `SecurityIncident` | Sentinel インシデント |
| `SigninLogs` | Entra ID 対話型サインイン |
| `AADNonInteractiveUserSignInLogs` | 非対話型サインイン |
| `AzureActivity` | Azure 管理操作の監査ログ |
| `AZFWNetworkRule` / `AZFWApplicationRule` | Firewall の許可/拒否ログ |
| `SecurityEvent` | Windows セキュリティイベント |
| `CommonSecurityLog` | CEF 形式のセキュリティログ |

> これらのテーブルは [監視基盤](#監視基盤) セクションの LAW アーカイブ設定により、長期保存も自動化されています。

#### 運用の流れ

```
1. ログ収集（自動）
   Azure Policy → 全リソースのログを LAW に送信

2. 脅威検出（自動）
   Sentinel 分析ルール → 異常パターンを検出 → インシデント生成

3. 調査（手動 / 半自動）
   Azure Portal → Sentinel → インシデント → タイムライン・エンティティ調査

4. 対応（手動 / 自動）
   ├── 手動: インシデントのステータス変更・担当者割り当て
   └── 自動: プレイブック（Logic App）で通知・隔離・チケット作成
```

---

## セットアップ手順

### 前提条件

| 要件 | 詳細 |
|:---|:---|
| **Azure サブスクリプション** | 4 つ（Management, Connectivity, Identity, Security） |
| **Terraform** | >= 1.9（推奨: 1.12+） |
| **認証** | `az login` または サービスプリンシパル / マネージド ID |
| **権限** | テナントルートで Owner または User Access Administrator + Contributor |
| **Azure Storage Account** | Terraform state backend 用（本番環境。テストはローカル state 可） |

### 1. 設定ファイルの準備

まず、本リポジトリのコードをcloneやforkして手元に置いてください。

```bash
cd alz-simple
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を編集し、以下を設定します：

```hcl
root_id   = "alz"               # 管理グループ階層のプレフィックス
root_name = "Azure Landing Zones"

primary_location = "japaneast"   # プライマリリージョン

# サブスクリプションID。それぞれ異なるサブスクリプションを設定しないとエラーになる。
subscription_ids = {  
  management   = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  connectivity = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  identity     = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  security     = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}

# DR 切替用のアクティブ Hub（通常は primary、DR 時に secondary に切替）
active_hub_key = "primary"

hub_virtual_networks = {
  primary = {
    location                            = "japaneast"
    address_space                       = ["10.0.0.0/16"]
    gateway_subnet_prefix               = "10.0.0.0/27"
    bastion_subnet_prefix               = "10.0.1.0/26"
    firewall_subnet_prefix              = "10.0.2.0/26"
    firewall_management_subnet_prefix   = null
    dns_resolver_inbound_subnet_prefix  = "10.0.3.0/26"
    dns_resolver_outbound_subnet_prefix = "10.0.4.0/26"
    firewall_sku_tier                   = "Standard"
    firewall_threat_intel_mode          = "Deny"
    # gateway_sku                       = "ErGw1AZ"  # デフォルト: ErGw1AZ（ゾーン冗長）
    express_route = {
      service_provider_name = "Equinix"
      peering_location      = "Tokyo"
      bandwidth_in_mbps     = 50
    }
  }
  # DR 用セカンダリ Hub（常時デプロイ済み、active_hub_key で切替）
  # secondary = {
  #   location                            = "japanwest"
  #   address_space                       = ["10.1.0.0/16"]
  #   gateway_subnet_prefix               = "10.1.0.0/27"
  #   bastion_subnet_prefix               = "10.1.1.0/26"
  #   firewall_subnet_prefix              = "10.1.2.0/26"
  #   firewall_management_subnet_prefix   = null
  #   dns_resolver_inbound_subnet_prefix  = "10.1.3.0/26"
  #   dns_resolver_outbound_subnet_prefix = "10.1.4.0/26"
  #   firewall_sku_tier                   = "Standard"
  #   firewall_threat_intel_mode          = "Deny"
  #   # gateway_sku                       = "ErGw1AZ"
  #   express_route = {
  #     service_provider_name = "Equinix"
  #     peering_location      = "Osaka"
  #     bandwidth_in_mbps     = 50
  #   }
  # }
}

# サブスクリプション新規作成時の課金スコープ（Vending で subscription_id 省略時に必須）
# EA:  /providers/Microsoft.Billing/billingAccounts/{id}/enrollmentAccounts/{id}
# MCA: /providers/Microsoft.Billing/billingAccounts/{id}/billingProfiles/{id}/invoiceSections/{id}
billing_scope_id = "/providers/Microsoft.Billing/billingAccounts/1234567890/enrollmentAccounts/0123456"
```

### 2. 初期化

```bash
# ローカル state（テスト用）の場合。リモートstateの場合は不要。
terraform init -backend-config=false

# リモート stateでストレージアカウントを使う場合。テストでローカルstateを使う場合は不要。
terraform init \
  -backend-config="resource_group_name=rg-terraform-state" \
  -backend-config="storage_account_name=stterraformstate" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=alz.terraform.tfstate"
```

### 3. デプロイ

```bash
terraform plan -out=tfplan    # 作成されるリソースを確認
terraform apply tfplan         # デプロイ実行（約 45〜55 分）
```

### 4. サブスクリプション追加（Vending）

```bash
# テンプレートをコピーして編集
cp subscriptions/templates/corp-template.yaml subscriptions/hr-system.yaml
vim subscriptions/hr-system.yaml

# デプロイ
terraform plan    # 追加されるリソースを確認
terraform apply   # デプロイ
```

---


### ポリシーのカスタマイズ例

#### 特定のポリシーを除外する

```yaml
# lib/archetype_definitions/landing_zones_custom.yaml
policy_assignments_to_remove:
  - Enable-DDoS-VNET    # コメントを外すと除外される
```

#### カスタムポリシーを追加する

1. `lib/policy_definitions/` にポリシー JSON を追加
2. `lib/policy_set_definitions/` にイニシアティブ JSON を追加（任意）
3. `lib/policy_assignments/` に割り当て JSON を追加
4. 対象 MG のアーキタイプ YAML で割り当てを参照

---

## GitHub Actions CI/CD

本リポジトリでは 7 つの GitHub Actions ワークフローでインフラのライフサイクルを管理します。

| ワークフロー | ファイル | トリガー | 概要 |
|:---|:---|:---|:---|
| **Terraform CI** | `ci.yaml` | PR → main | fmt + validate + plan、結果を PR コメントに貼付 |
| **Terraform CD** | `cd.yaml` | push main / 手動 | apply（自動）または destroy（手動選択） |
| **Drift Detection** | `drift-detection.yaml` | 毎日 09:00 JST / 手動 | state と実環境の差分を検知し Issue 管理 |
| **Dependency Check** | `dependency-check.yaml` | PR（lock/provider 変更時）/ 手動 | lock file 整合性 + provider バージョン検証 |
| **Library Update Check** | `library-update-check.yaml` | 毎週月曜 / 手動 | ALZ/AMBA ポリシーライブラリの新バージョンを検知し Issue 作成 |
| **Policy Remediation** | `policy-remediation.yaml` | 手動のみ | DINE/Modify ポリシーの修復タスク作成（既存リソース対応） |
| **Provider Major Check** | `provider-major-check.yaml` | 毎週月曜 / 手動 | Terraform プロバイダーのメジャーバージョン更新検知 → Issue 作成 |

### デプロイフロー

![CI/CD デプロイフロー](diagrams/readme-08-cicd-deploy-flow.svg)

### CI/CD 実装手順

以下の手順で CI/CD パイプラインをゼロから構築します。

#### Step 1: Terraform state backend の作成

CI/CD で使う Remote State 用の Azure Storage Account を作成します。
state backend は Terraform 管理外で事前に作成する必要があります。（通常はManagement用サブスクリプションに作成します）

```bash
# 変数
RG_NAME="rg-terraform-state"
LOCATION="japaneast"
# ストレージアカウント名はグローバルで一意にする
SA_NAME="stterraformstate$(openssl rand -hex 4)"
CONTAINER_NAME="tfstate"

# リソースグループ
az group create --name "$RG_NAME" --location "$LOCATION"

# ストレージアカウント（GRS、Blob バージョニング有効）
# GRS（geo 冗長）によりリージョン障害時も state を保護
az storage account create \
  --name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --location "$LOCATION" \
  --sku Standard_GRS \
  --allow-blob-public-access false \
  --min-tls-version TLS1_2

# Blob バージョニング有効化（state の履歴保持）
az storage account blob-service-properties update \
  --account-name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --enable-versioning true

# Blob ソフトデリート有効化（誤削除から 30 日間復元可能）
az storage account blob-service-properties update \
  --account-name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --enable-delete-retention true \
  --delete-retention-days 30

# コンテナソフトデリート有効化
az storage account blob-service-properties update \
  --account-name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --enable-container-delete-retention true \
  --container-delete-retention-days 30

# コンテナ
az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$SA_NAME" \
  --auth-mode login
```

#### Step 2: ユーザーマネージド ID（UAMI）の作成

GitHub Actions から Azure への認証には OIDC（OpenID Connect）を使用します。
シークレットの管理が不要で、短命トークンによるセキュアな認証が可能です。
AzureではユーザーマネージドIDを使って簡単に実装できます。

```bash
# UAMI 作成（Management サブスクリプション推奨）
UAMI_NAME="uami-github-actions"
az identity create \
  --name "$UAMI_NAME" \
  --resource-group "$RG_NAME" \
  --location "$LOCATION"

# 出力されたクライアント ID を控える
CLIENT_ID=$(az identity show \
  --name "$UAMI_NAME" \
  --resource-group "$RG_NAME" \
  --query clientId -o tsv)
echo "CLIENT_ID: $CLIENT_ID"
```

#### Step 3: フェデレーション資格情報の追加

GitHub Actions の OIDC トークンと UAMI を紐付けます。
以下の **3 つの資格情報**が必要です。

| 資格情報名 | subject | 用途 |
|---|---|---|
| `github-main` | `ref:refs/heads/main` | CI: main ブランチ push 時の plan |
| `github-pr` | `pull_request` | CI: PR 作成・更新時の validate + plan |
| `github-environment-azure` | `environment:azure` | CD: apply / destroy（GitHub Environment 経由） |

```bash
# GitHubの情報を設定してください。
GITHUB_ORG="<your-github-org-or-user>"
GITHUB_REPO="<your-repo-name>"

# main ブランチ用（CI: main push 時の plan で使用）
az identity federated-credential create \
  --name "github-main" \
  --identity-name "$UAMI_NAME" \
  --resource-group "$RG_NAME" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main" \
  --audiences "api://AzureADTokenExchange"

# PR 用（CI: validate + plan で使用）
az identity federated-credential create \
  --name "github-pr" \
  --identity-name "$UAMI_NAME" \
  --resource-group "$RG_NAME" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:${GITHUB_ORG}/${GITHUB_REPO}:pull_request" \
  --audiences "api://AzureADTokenExchange"

# GitHub Environment 用（CD: apply/destroy で使用）
# cd.yaml の apply/destroy ジョブは `environment: azure` を指定するため、
# OIDC トークンの subject が `environment:azure` になります。
az identity federated-credential create \
  --name "github-environment-azure" \
  --identity-name "$UAMI_NAME" \
  --resource-group "$RG_NAME" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:azure" \
  --audiences "api://AzureADTokenExchange"
```

> **重要**: `subject` の形式が間違っていると OIDC 認証が `AADSTS700213` エラーで失敗します。
> ブランチ指定は `ref:refs/heads/main`、PR は `pull_request`、GitHub Environment は `environment:<環境名>` です。
> CD ワークフローの `apply` / `destroy` ジョブは `environment: azure` を使用するため、
> `environment:azure` の資格情報がないと CD で認証エラーになります。

#### Step 4: UAMI へのロール割り当て

テナントルートスコープで Owner ロールを付与します。
管理グループ・サブスクリプション・ポリシー・RBAC すべてを操作するため、Owner が必要です。

```bash
UAMI_PRINCIPAL_ID=$(az identity show \
  --name "$UAMI_NAME" \
  --resource-group "$RG_NAME" \
  --query principalId -o tsv)

# テナントルートに Owner を付与
az role assignment create \
  --assignee-object-id "$UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Owner" \
  --scope "/"
```

さらに、state backend の Storage Account に対して `Storage Blob Data Contributor` を付与します。

```bash
SA_ID=$(az storage account show \
  --name "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --query id -o tsv)

az role assignment create \
  --assignee-object-id "$UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$SA_ID"
```

#### Step 5: GitHub リポジトリの Secrets 設定

GitHub リポジトリの **Settings → Secrets and variables → Actions** で以下の 6 つの Repository Secrets を登録します。

| Secret | 値の例 | 説明 |
|:---|:---|:---|
| `AZURE_CLIENT_ID` | `0379e382-1a60-...` | Step 2 で控えた UAMI のクライアント ID |
| `AZURE_TENANT_ID` | `8917ed35-ff3e-...` | Azure テナント ID（`az account show --query tenantId`） |
| `AZURE_SUBSCRIPTION_ID` | `xxxxxxxx-xxxx-...` | state backend があるサブスクリプション ID |
| `BACKEND_RESOURCE_GROUP` | `rg-terraform-state` | Step 1 で作成したリソースグループ名 |
| `BACKEND_STORAGE_ACCOUNT` | `stterraformstated7175ded` | Step 1 で作成したストレージアカウント名 |
| `BACKEND_CONTAINER` | `tfstate` | Step 1 で作成したコンテナ名 |

```bash
# CLI で設定する場合（gh コマンド）
gh secret set AZURE_CLIENT_ID --body "$CLIENT_ID"
gh secret set AZURE_TENANT_ID --body "$(az account show --query tenantId -o tsv)"
gh secret set AZURE_SUBSCRIPTION_ID --body "$(az account show --query id -o tsv)"
gh secret set BACKEND_RESOURCE_GROUP --body "$RG_NAME"
gh secret set BACKEND_STORAGE_ACCOUNT --body "$SA_NAME"
gh secret set BACKEND_CONTAINER --body "$CONTAINER_NAME"
```

#### Step 6: GitHub Environment の作成

CD ワークフローの apply / destroy 実行前に承認ゲートを設けます。
承認者の確認なしにインフラ変更が本番反映されることを防ぎます。

**Settings → Environments → New environment** で以下を設定します。

| 設定 | 値 |
|:---|:---|
| **Environment name** | `azure` |
| **Required reviewers** | ✅（承認者を 1 名以上指定） |
| **Deployment branches** | `main` のみ |

> **ポイント**: CD ワークフローの deploy / destroy ジョブに `environment: azure` を設定済みです。main マージ後、指定された承認者が GitHub 上で承認するまで apply は実行されません。destroy も同様に承認が必要なため、誤操作によるインフラ全削除を防止できます。

#### Step 7: ブランチ保護ルールの設定

`main` ブランチへの直接プッシュを禁止し、PR 経由のみでマージ可能にします。
承認を必須にする仕組みで、基盤管理では重要です。

**Settings → Rules → Rulesets** で以下を設定します。

| 設定 | 値 |
|:---|:---|
| **Ruleset Name** | `main-protection` |
| **Enforcement status** | Active |
| **Bypass list** | Repository admin（緊急時のみ） |
| **Target branches** | `main` |
| **Restrict deletions** | ✅ |
| **Require a pull request before merging** | ✅ |
| **Required approvals** | 1（レビュアー数） |
| **Require status checks to pass** | ✅ |
| **Required checks** | `Validate & Plan`（CI ワークフローのジョブ名） |

> **ポイント**: Required checks に CI ジョブ名 `Validate & Plan` を追加することで、plan が失敗した PR はマージできなくなります。

### ワークフローの詳細

#### Terraform CI（`ci.yaml`）

PR 作成時に自動実行され、コードの妥当性と plan 結果をレビュアーに提示します。

```
PR 作成/更新
  → terraform fmt -check（フォーマット検証）
  → terraform init → validate → plan
  → plan 出力を PR コメントに自動投稿
  → plan 失敗時はワークフロー失敗（マージブロック）
```

| 設定 | 値 | 説明 |
|:---|:---|:---|
| **トリガー** | `pull_request: branches: [main]` | main 向け PR のみ |
| **fmt -check** | `-recursive` | フォーマット違反を早期検出（init より前に実行） |
| **permissions** | `id-token: write`, `pull-requests: write` | OIDC 認証 + PR コメント投稿 |
| **plan 出力** | PR コメントに貼付 | 65,536 文字を超える場合は自動で先頭/末尾を切り出し |
| **lock-timeout** | `60m` | 他のワークフロー実行中の state ロック待ち |

#### Terraform CD（`cd.yaml`）

main マージ時に Plan → 承認 → Apply、手動実行で apply/destroy を選択できます。
Plan の結果は Job Summary に出力され、承認者は **変更内容を確認した上で承認** できます。

```
main マージ（push）→ Plan ジョブ: init → validate → plan（Summary に出力）
                     → Apply ジョブ: 承認待ち → apply（plan ファイルを Artifact 経由で引き継ぎ）
                     ※ plan で変更なしの場合、Apply ジョブはスキップ

手動（dispatch）  → action: apply   → 上記と同じフロー
                  → action: destroy → Plan Destroy ジョブ: plan -destroy（Summary に出力）
                                       → Destroy ジョブ: 承認待ち → Pre-Destroy Cleanup → destroy
```

| 設定 | 値 | 説明 |
|:---|:---|:---|
| **トリガー** | `push: branches: [main]` + `workflow_dispatch` | 自動 + 手動 |
| **Plan → 承認 → Apply** | 3 ステップ分離 | plan 結果を確認してから承認・apply |
| **environment** | `azure`（Apply / Destroy のみ） | 承認者が Job Summary で plan 結果を確認後に承認 |
| **plan Artifact** | `upload-artifact` → `download-artifact` | plan ファイルをジョブ間で引き継ぎ |
| **変更なしスキップ** | `-detailed-exitcode` で判定 | 変更がない場合は Apply ジョブ自体をスキップ |
| **Job Summary** | plan 出力を Summary に表示 | 承認画面から plan 結果へのリンクで確認可能 |
| **terraform_wrapper** | `false`（Plan / Destroy） | exit code を正しく取得するため |
| **Pre-Destroy Cleanup** | DenyAction ポリシー削除 + WORM SA クリーンアップ | destroy 前に削除障害の原因を自動除去（REST API + SAS） |

#### Drift Detection（`drift-detection.yaml`）

state と実環境の差分を毎日検知し、GitHub Issue で通知します。

| 設定 | 値 | 説明 |
|:---|:---|:---|
| **スケジュール** | `cron: "0 0 * * *"`（09:00 JST） | 毎日 1 回 |
| **terraform_wrapper** | `false` | exit code を正しく取得するため |
| **-detailed-exitcode** | 0=差分なし / 2=ドリフト / 1=エラー | exit code で後続ステップを分岐 |
| **Issue ラベル** | `drift-detected` | 自動作成/更新/クローズ |

#### Dependency Check（`dependency-check.yaml`）

lock file やプロバイダー定義の変更を含む PR で自動実行されます。
base ブランチとの lock file を比較し、プロバイダーごとのバージョン変更を SemVer で分析します。

| 設定 | 値 | 説明 |
|:---|:---|:---|
| **トリガー** | `paths: [".terraform.lock.hcl", "terraform.tf"]` | プロバイダー関連ファイルのみ |
| **バージョン比較** | base ↔ PR の lock file を diff | プロバイダーごとの変更前後を表で表示 |
| **リスク判定** | SemVer 分析 | 🔴 メジャー / 🟡 マイナー / 🟢 パッチ / 🆕 新規 / 🗑️ 削除 |
| **lock 整合性** | `terraform providers lock` で再生成 → diff | ハッシュの不一致を検出 |
| **レビューチェックリスト** | リスクレベルに応じて動的生成 | メジャー変更時は Breaking Changes 確認 + ロールバック準備 |
| **コメント重複回避** | 既存コメントを更新 | 再実行時に PR コメントが増殖しない |

### Concurrency 制御

CI、CD、Drift Detection の 3 ワークフローは同じ `concurrency group` を共有しています。
ほかのワークフローが実行中の場合、State競合を避けるため終了を待つようにしています。

```yaml
concurrency:
  group: terraform-state
  cancel-in-progress: false   # 実行中のジョブはキャンセルしない
```

| 動作 | 説明 |
|:---|:---|
| **State ロック競合を防止** | 同時に 2 つのワークフローが `terraform apply/plan` を実行すると state ロック競合が発生する。concurrency group でキューイングされ順番に実行される |
| **cancel-in-progress: false** | 実行中のジョブはキャンセルせず完了を待つ。`true` にするとインフラ操作が途中で中断される危険があるため **必ず false** |
| **lock-timeout: 60m** | concurrency group でキューイングされても、state ロック取得を最大 60 分待機するため、タイムアウトしにくい |

---

## 構成ドリフト検知

Terraform の state と実際の Azure インフラの差分（ドリフト）を毎日自動検知します。
手動変更や Azure 側の自動更新による意図しない変更を早期発見できます。

### 仕組み

```
スケジュール（毎日 09:00 JST）または手動実行
│
└── terraform plan -detailed-exitcode
    │
    ├── 終了コード 0 → ドリフトなし → 既存の drift Issue を自動クローズ
    ├── 終了コード 2 → ドリフト検知 → GitHub Issue を作成/更新
    └── 終了コード 1 → エラー → ワークフロー失敗
```

### Issue 管理

- ドリフト検知時、`drift-detected` ラベル付きの Issue を自動作成します
- plan 出力が Issue 本文に記載されるため、何が変わったか一目でわかります
- 既に open の Issue がある場合は重複作成せず、既存 Issue を更新します
- ドリフトが解消されると、次回の検知で Issue が自動クローズされます

### 対処方法

| ケース | 対処 |
|:---|:---|
| 意図した手動変更 | Terraform コードを更新して PR を作成 |
| 意図しない変更 | `terraform apply` で state と一致させる |
| 一時的な差分 | 次回検知で自動クローズされるので放置可 |

---

## 依存バージョン管理

本構成には **3 種類の依存** があり、それぞれ異なる仕組みで自動追跡しています。

| 依存の種類 | 対象 | マイナー/パッチ追跡 | メジャー追跡 | 更新アクション |
|:---|:---|:---|:---|:---|
| **Terraform プロバイダー** | azurerm, azapi, alz, time | Dependabot（週次 PR） | Provider Major Version Check（週次 Issue） | PR レビュー → マージ / 手動対応 |
| **ポリシーライブラリ** | ALZ (`platform/alz`), AMBA (`platform/amba`) | — (完全ピン) | Library Update Check（週次 Issue） | 手動で `policy.tf` の `ref` を更新 |
| **GitHub Actions** | checkout, setup-terraform, github-script | Dependabot（週次 PR） | Dependabot（週次 PR） | PR レビュー → マージ |

> **注意**: Dependabot の `terraform` エコシステムは `required_providers` の `~>` 制約範囲内のみ追跡します。メジャーバージョン（例: azurerm 4.x → 5.x）は制約外のため Dependabot では検知できません。Provider Major Version Check ワークフローがこのギャップを補完します。

### Dependabot（Terraform プロバイダー）

GitHub Dependabot が `terraform.tf` の `required_providers` と `.terraform.lock.hcl` を週次でスキャンし、新バージョンがある場合は自動で PR を作成します。

| 設定 | 値 |
|:---|:---|
| スキャン頻度 | 毎週月曜 09:00 JST |
| 対象 | Terraform プロバイダー |
| ラベル | `dependencies`, `terraform` |
| レビュアー | 自動アサイン |
| 同時 PR 上限 | 5 |

### Dependabot（GitHub Actions）

GitHub Dependabot がワークフロー内の `uses:` で参照するアクションのバージョンを週次でスキャンし、新バージョンがある場合は自動で PR を作成します。

| 設定 | 値 |
|:---|:---|
| スキャン頻度 | 毎週月曜 09:00 JST |
| 対象 | GitHub Actions（`actions/checkout`, `hashicorp/setup-terraform` 等） |
| ラベル | `dependencies`, `github-actions` |
| レビュアー | 自動アサイン |

### Provider Major Version Check ワークフロー

Terraform プロバイダーのメジャーバージョン更新を週次で検出し、Issue で通知します。
`~>` 制約の範囲外（メジャーバージョン更新）は Dependabot では検知できないため、このワークフローで補完します。

```
毎週月曜（または手動実行）
  → Terraform Registry API で各プロバイダーの最新バージョンを取得
  → terraform.tf の ~> 制約のメジャーバージョンと比較
  → メジャー更新あり → provider-major-update ラベル付き Issue を作成/更新
  → メジャー更新なし → 既存 Issue を自動クローズ
```

| 設定 | 値 |
|:---|:---|
| スキャン頻度 | 毎週月曜 09:00 JST |
| 対象 | `azurerm`, `azapi`, `alz`, `time` |
| 通知方法 | GitHub Issue（`provider-major-update` ラベル） |
| 更新手順 | Issue に記載（制約更新 → コード修正 → PR → CI plan 確認 → マージ） |

### Dependency Check ワークフロー

Dependabot PR や手動のプロバイダー変更時に、プロバイダーのバージョン変更を SemVer で分析し、リスク評価付きで PR にレポートします。

```
Dependabot → バージョン更新 PR 自動作成
                 ↓
        CI（plan 確認）+ Dependency Check（SemVer 分析 + lock file 検証）
                 ↓
        レビュー → マージ → CD apply
```

- base ブランチと PR の lock file を比較し、プロバイダーごとの変更を検出
- SemVer でリスクを自動判定（🔴 メジャー / 🟡 マイナー / 🟢 パッチ）
- プロバイダーの追加（🆕）・削除（🗑️）も検出
- `terraform providers lock` で lock file の整合性を検証
- `terraform validate` で構文互換性を確認
- リスクレベルに応じたレビューチェックリストを PR コメントに生成
- 再実行時は既存コメントを更新（重複回避）

### Library Update Check ワークフロー（ALZ / AMBA ポリシーライブラリ）

`policy.tf` の `library_references` で参照している ALZ / AMBA ポリシーライブラリの新バージョンを週次で検出し、Issue で通知します。

```
毎週月曜（または手動実行）
  → GitHub API で Azure/Azure-Landing-Zones-Library の最新リリースを取得
  → policy.tf の ref と比較
  → 差分あり → library-update ラベル付き Issue を作成/更新
  → 差分なし → 既存 Issue を自動クローズ
```

| 設定 | 値 |
|:---|:---|
| スキャン頻度 | 毎週月曜 09:00 JST |
| 対象 | `platform/alz`, `platform/amba` |
| 通知方法 | GitHub Issue（`library-update` ラベル） |
| 更新手順 | Issue に記載（`ref` を更新 → init → plan → PR） |

### Policy Remediation ワークフロー

DINE（DeployIfNotExists）/ Modify ポリシーは**新規リソースには自動適用**されますが、**既存リソースには修復タスクが必要**です。
このワークフローは手動実行で、全管理グループのDINE/Modify割り当てに対して修復タスクを一括作成します。

```
手動実行（workflow_dispatch）
  → 管理グループ階層を再帰スキャン
  → identity を持つ割り当て（= DINE/Modify）を収集
  → イニシアティブ: メンバーポリシーごとに修復タスクを作成
  → 単一ポリシー: 直接修復タスクを作成
```

| 設定 | 値 |
|:---|:---|
| トリガー | 手動のみ（`workflow_dispatch`） |
| 対象 | 全管理グループの DINE/Modify 割り当て |
| 修復モード | `ExistingNonCompliant`（既存の非準拠リソースのみ） |

> **使用タイミング**: ポリシーライブラリの更新後や、新しい DINE ポリシーを追加した後に実行してください。
> 新規リソースは自動的にポリシーが適用されるため、日常的な実行は不要です。

---

## 技術補足

本章では、コード理解を深めるための技術的な補足情報をまとめています。

### azapi と azurerm の使い分け

本構成では意図的に `azapi` と `azurerm` を使い分けています。

#### azapi を選択する 4 つの理由

| # | 理由 | 該当リソース | 説明 |
|:---:|:---|:---|:---|
| 1 | **retry ブロック** | DCR, DNS Zone, Peering, Policy | Azure API の一時的エラーに自動リトライ。`azurerm` にはこの機能がない |
| 2 | **クロスサブスクリプション** | Vending 全リソース | フルリソース ID で任意のサブスクリプションを操作。provider alias 不要 |
| 3 | **REST API body 直接渡し** | Policy 5 種類 | ALZ プロバイダーの JSON 出力をそのまま流し込める |
| 4 | **azurerm 未対応機能** | DCR (CT, SQL) | extension データソースが azurerm では未サポート |

#### azurerm を選択する場合

| 理由 | 説明 |
|:---|:---|
| **コードの読みやすさ** | HCL ネイティブの属性定義は JSON body より直感的 |
| **plan の差分表示** | azurerm の方が属性レベルの差分が見やすい |
| **バリデーション** | azurerm はスキーマ検証が厳密 |
| **ライフサイクル管理** | `create_before_destroy` 等のメタ引数が利用しやすい |

#### 判断フローチャート

| 判断条件 | → | 選択 |
|:---|:---:|:---|
| リトライが必要？ | **Yes** | → `azapi` |
| クロスサブスクリプション？ | **Yes** | → `azapi` |
| ALZ JSON をそのまま流す？ | **Yes** | → `azapi` |
| azurerm で機能サポート？ | **No** | → `azapi` |
| 上記すべて No | — | → `azurerm` |

### リトライメカニズム一覧

Azure API の一時的エラーに対して、すべて自動リトライが設定されています。
これにより、**1 回の `terraform apply` で全リソースが作成完了** します。
万が一、terraform applyが失敗しても、terraformは冪等なので再度terraform applyをすれば成功することがほとんどです。

| リソース | エラーパターン | 間隔 | 最大間隔 | 原因 |
|:---|:---|:---:|:---:|:---|
| DCR VM Insights | `InvalidPayload` | 30s | 300s | LAW テーブル未完了 |
| DCR Change Tracking | `InvalidOutputTable` | 30s | 300s | Solution テーブル作成待ち |
| DCR Defender SQL | `InvalidOutputTable` | 30s | 300s | 同上 |
| Private DNS Zone | `Conflict`, `409` | 10s | 60s | 56 ゾーン同時作成の API 衝突 |
| Policy Assignments | `out of scope` | 30s | 300s | MG 伝搬遅延 |
| Role Definitions | `NotFound` | 15s | 120s | MG 伝播遅延 |
| Policy Role Assignments | `AuthorizationFailed` | 30s | 300s | MG RBAC 伝播遅延 |
| Vending Subnets | `AnotherOperationInProgress` | 10s | 60s | VNet 操作競合 |
| Vending Spoke→Hub | `RemoteVnetHasNoGateways` | 30s | 300s | ER Gateway 未完了 |
| Vending Hub→Spoke | `AnotherOperationInProgress` | 30s | 300s | VNet 操作競合 |

#### なぜリトライが必要なのか

Azure のリソース作成は **非同期** です。API が `200 OK` を返しても、内部的にはプロビジョニングが続いている場合があります。

```
例: 管理グループの伝搬

terraform apply
  → MG "root" 作成 → API: 200 OK（作成完了）
  → MG "platform" 作成 → API: 404 Not Found
    ↑ Azure 内部でまだ MG ツリーの伝搬が完了していない

解決方法:
  ① time_sleep で固定時間待機（管理グループ間）
  ② azapi retry で自動リトライ（その他全て）
```

`azurerm` にはリトライ機能がないため、これらのリソースは `azapi` で作成する必要があります。

### デプロイ依存チェーン

`terraform apply` 実行時、リソースは以下の順序で作成されます。
並行実行可能なものは同時に作成され、依存関係のあるものは順序が保証されます。

![デプロイ依存チェーン（4 フェーズ）](diagrams/readme-07-deploy-dependency-chain.svg)

#### ボトルネックと依存順序

**ER Gateway のプロビジョニング** が最大のボトルネックで、約 25〜30 分かかります。
ER Gateway は VNet レベルの書き込みロックを長時間保持するため、他の VNet 操作（Bastion や DNS Resolver のデプロイ）と競合します。
さらに、DNS Resolver と Bastion も同一 VNet を操作するため、同時実行すると VNet の `provisioningState` が `Updating` となり `BadRequest` エラーが発生します。
これを避けるため、以下の依存順序を設定しています。

```
VNet
├── 全サブネット（並列作成）
│
└── ER Gateway（depends_on = 全サブネット）  ← 約30分、VNet ロック保持
    │
    └── VNet ロック解放後（直列化）
        └── DNS Resolver → Inbound/Outbound Endpoints
            └── Bastion Host  ← DNS Resolver 完了後に開始
```

全体の所要時間は ER Gateway + DNS Resolver + Bastion（約 45〜55 分）です。

---

## よくある質問

### Q: ローカル state とリモート state の違いは？

| | ローカル state | リモート state（本リポジトリ） |
|---|---|---|
| **保存先** | 作業マシンの `terraform.tfstate` ファイル | Azure Blob Storage |
| **共有** | 不可（個人の PC に依存） | チーム全員・CI/CD が同一 state を参照 |
| **排他ロック** | なし（同時実行で競合・破損のリスク） | Blob リースで自動排他ロック |
| **バックアップ** | 手動管理 | Blob バージョニング・GRS で自動保護 |
| **セキュリティ** | ファイルに機密情報が平文で残る | RBAC + 暗号化で保護 |

本リポジトリでは `terraform.tf` の `backend "azurerm"` でリモート state を使用しています。
`terraform init` 時に backend 設定が渡され、以降のすべての操作はリモート state に対して行われます。
ローカルに `terraform.tfstate` は作成されません。

### Q: `terraform apply` が途中で失敗した場合は？

すべてのリトライ可能なエラーは `azapi` の `retry` ブロックで自動処理されます。
万が一失敗した場合は、そのまま再度 `terraform apply` を実行してください。
Terraform は state に記録済みのリソースをスキップし、未作成のリソースのみ作成します。（冪等）

### Q: 約 900 リソースもあるが plan が遅くないか？

`terraform plan` は約 5〜8 分かかります。これは Azure API への問い合わせが多いためです。

### Q: ER Gateway なしで使えるか？

はい。`terraform.tfvars` の `hub_virtual_networks` で `gateway_subnet_prefix = null` に設定すれば、ER 関連リソースは作成されません。
VNet ロックの競合も発生しないため、デプロイ時間が大幅に短縮されます。
Spoke VNet では `use_hub_gateway: false` に設定してください。

### Q: 既存のサブスクリプションを Landing Zone に追加できるか？

はい。`subscriptions/` に YAML ファイルを置き、既存サブスクリプションの ID を記入するだけです。
既にリソースがある場合、Terraform は YAML に定義されたリソースのみ追加で作成します。

### Q: DR（災害復旧）切替の手順は？

`terraform.tfvars` の `active_hub_key` を `"primary"` から `"secondary"` に変更し、PR を作成してマージします。
CD パイプラインが自動で apply し、全 Spoke VNet のピアリング先がセカンダリ Hub に切り替わります。
切り戻しは同様に `active_hub_key` を `"primary"` に戻すだけです。

### Q: サブスクリプション追加後、反映されるまでどのくらいかかる？

YAML を追加して PR をマージすると、CD パイプラインで自動デプロイされます。
Spoke VNet・サブネット・ピアリング・ルートテーブル・AMBA アラートの作成まで、通常 10〜15 分で完了します。

### Q: ポリシーの適用を一時的に無効化したい場合は？

`lib/archetype_definitions/` の対象アーキタイプ YAML で `policy_assignments_to_remove` にポリシー名を追加します。
コード変更 → PR → マージのフローで安全に無効化できます。ポータルからの手動変更は構成ドリフトとして検知されます。

### Q: Firewall なしで使えるか？

現在の構成では Firewall は Hub VNet の必須コンポーネントです。
Firewall を除外するには `network-hub.tf` の Firewall 関連リソースをコメントアウトし、ルートテーブルのネクストホップを変更する必要があります。

### Q: State ロックでエラーが出た場合は？

CI/CD の concurrency group により同時実行は抑制されていますが、手動実行とワークフローが競合する場合があります。
State ファイルは Azure Blob Storage のリースで排他ロックされています。解除するには、Azure Portal でストレージアカウント → コンテナー → `alz.terraform.tfstate` Blob を選択し、**リースの解除（Break lease）** を実行してください。

```
# Azure CLI でも解除可能
az storage blob lease break \
  --account-name <STORAGE_ACCOUNT> \
  --container-name <CONTAINER> \
  --blob-name alz.terraform.tfstate \
  --auth-mode login
```

### Q: `terraform destroy` で一部リソースが削除できない場合は？

以下のリソースは `terraform destroy` で削除が失敗・不完全になることがあります。

| リソース | 原因 | 対処 |
|---|---|---|
| **管理グループ** | Azure のソフトデリート（論理削除）で保持される | Azure Portal →「管理グループ」から完全削除 |
| **Key Vault** | 既定でソフトデリートが有効（削除保護付き） | Azure Portal →「削除されたコンテナー」から復旧または完全削除 |
| **リソースロック付きリソース** | delete lock が設定されている場合、削除がブロックされる | ロックを手動削除後に再実行 |
| **依存関係のあるリソース** | ピアリング先・サブネット委任等が残存している場合 | 依存リソースを先に削除してから再実行 |
| **LAW アーカイブ Storage Account** | `AccountProtectedFromDeletion` — バージョンレベル不変性が有効なため削除保護される | **CD では自動処理済**（Pre-Destroy Cleanup ステップ: パブリックアクセス有効化 → Blob 不変性ポリシー削除 → Blob 削除 → SA 削除）。手動 destroy の場合は Blob の不変性ポリシーを全て削除してから SA を削除（[詳細手順](#不変ポリシーworm)） |
| **AMA 用 UAMI** | `RequestDisallowedByPolicy` — ALZ の `DenyAction-DeleteUAMIAMA` ポリシーが削除を拒否 | **CD では自動処理済**（Pre-Destroy Cleanup ステップで DenyAction ポリシーを事前削除）。手動 destroy の場合は `az policy assignment delete` で DenyAction 割り当てを削除してから再実行 |
| **azapi リソース全般** | `Missing Resource Identity After Read` — Azure 側で既に削除済み | `terraform state rm <RESOURCE>` で state から除外 |

上記が複合して大量にエラーが出る場合は、Azure Portal 側でリソースグループごと手動削除した後、`terraform state push -force` で空の state に上書きしてください。

### Q: 既存の Azure リソースを Terraform state に import できるか？

はい。`terraform import` で既存リソースをリモート state に取り込めます。

```bash
# 1. リモート backend に接続した状態で import
terraform import '<TERRAFORM_RESOURCE_ADDRESS>' '<AZURE_RESOURCE_ID>'

# 例: 既存のリソースグループを import
terraform import 'azurerm_resource_group.example' '/subscriptions/<SUB_ID>/resourceGroups/<RG_NAME>'
```

import 後は `terraform plan` で差分がないことを確認してください。差分がある場合はコード側を実態に合わせて調整します。

> **注意**: import はリモート state に直接書き込みます。事前に Blob のスナップショットを取得し、問題があればロールバックできるようにしておくことを推奨します。

### Q: このリポジトリをフォークして自社用にカスタマイズする手順は？

1. リポジトリをフォーク
2. `terraform.tfvars` を自社環境に合わせて編集（サブスクリプション ID、リージョン、IP 範囲）
3. セットアップ手順に従い State backend と UAMI を作成
4. GitHub Secrets を設定
5. `terraform init` → `terraform plan` で確認
6. PR を作成してマージ → CD が自動デプロイ
