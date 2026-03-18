# ALZ-terraform — Azure Landing Zone

本プロジェクトは、AVM（Azure Verified Modules）を使わず、`azurerm` / `azapi` リソースのみで構築した Azure Landing Zone です。
すべてのコードが可視で、外部モジュールへの依存をできるだけ少なくしています。

> **想定読者**: Terraform の経験、 Azure Landing Zone を使用した経験のある方。
> Terraform 基礎（`resource`, `variable`, `output` 等）は既知として説明します。

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
9. [azapi と azurerm の使い分け](#azapi-と-azurerm-の使い分け)
10. [リトライメカニズム一覧](#リトライメカニズム一覧)
11. [デプロイ依存チェーン](#デプロイ依存チェーン)
12. [前提条件](#前提条件)
13. [セットアップ手順](#セットアップ手順)
14. [GitHub Actions CI/CD](#github-actions-cicd)
15. [構成ドリフト検知](#構成ドリフト検知)
16. [依存バージョン管理](#依存バージョン管理)

---

## 設計思想

### なぜ AVM を使わないのか

Azure Verified Modules (AVM) とは、Microsoftが用意しているTerraformのモジュールです。

[参考：Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)

Azure Verified Modules (AVM) は便利ですが、モジュール内部がブラックボックスになりがちで、外部コードに依存します。
本構成は以下の方針で設計しました。

| 方針 | 説明 |
|:---|:---|
| **全コード可視** | 外部モジュールを使わず、全リソースを `.tf` ファイルに直接記述しています。何が作られるか、コードを読めば 100% わかります。 |
| **1 ディレクトリ完結** | このリポジトリのファイルだけで Landing Zone 全体が動きます。モジュール依存の追跡が不要です。 |
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
alz-simple/
│
│  ── Terraform 基盤 ──────────────────────────────────────────
├── terraform.tf                  # プロバイダー定義・バージョン制約
├── variables.tf                  # 全入力変数（14 変数）
├── locals.tf                     # 計算値（Hub キー、DNS×VNet 直積）
├── outputs.tf                    # 出力値（12 個）
├── terraform.tfvars              # 環境固有の設定値
├── terraform.tfvars.example      # 上記の記入例
│
│  ── リソース定義 ────────────────────────────────────────────
├── management-groups.tf          # 管理グループ 11 個 + サブスクリプション配置
├── resource-groups.tf            # リソースグループ 4 種
├── management-resources.tf       # Log Analytics, Sentinel, UAMI, DCR × 3
├── network-hub.tf                # Hub VNet, Firewall, ExpressRoute, ルートテーブル
├── network-dns.tf                # Private DNS ゾーン 56 個 + VNet リンク
├── policy.tf                     # ポリシーデプロイエンジン
├── subscription-vending.tf       # YAML 駆動のサブスクリプション自動払い出し
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
│   └── policy_assignments/                # カスタム割り当て
│       └── Assign-IaC-Compliance.*.json
│
│  ── サブスクリプション定義 ──────────────────────────────────
└── subscriptions/
    ├── test-subscription.yaml             # テスト用サブスクリプション
    └── templates/
        ├── corp-template.yaml             # Corp 用テンプレート
        └── online-template.yaml           # Online 用テンプレート
```

### ファイルの読み方と使い方

| やりたいこと | 読むファイル |
|:---|:---|
| 新しいサブスクリプションを追加したい | `subscriptions/templates/` → コピーして YAML を編集 |
| ポリシーを除外したい | `lib/archetype_definitions/` のコメント行を解除 |
| カスタムポリシーを追加したい | `lib/policy_definitions/` に JSON 追加 |
| Firewall ルールを変更したい | `network-hub.tf` の `azurerm_firewall_policy_rule_collection_group` |
| Hub VNet の IP 範囲を変更したい | `terraform.tfvars` の `hub_virtual_networks` |
| 新しい DCR を追加したい | `management-resources.tf` にリソース追加 |
| デプロイが失敗した場合の調査 | [リトライメカニズム一覧](#リトライメカニズム一覧) を確認 |

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

---

## ネットワーク設計（Hub-Spoke）

### 概要

Hub-Spoke トポロジーは、中央の Hub VNet に共通のネットワーク機能（Firewall, Gateway, DNS）を集約し、各ワークロードの Spoke VNet をピアリングで接続する設計です。

![Hub-Spoke ネットワーク トポロジ](diagrams/readme-04-hub-spoke-network.svg)

### Hub VNet のサブネット構成

| サブネット | 用途 | 備考 |
|:---|:---|:---|
| `AzureFirewallSubnet` | Azure Firewall 専用 | 名前固定（Azure の要件） |
| `GatewaySubnet` | VPN/ER Gateway 専用 | 名前固定（Azure の要件） |
| `AzureBastionSubnet` | Bastion ホスト | 名前固定、条件付き作成 |
| `AzureFirewallManagementSubnet` | Firewall 管理用 | 強制トンネリング時に必要 |

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

### ルートテーブルの設計

| ルートテーブル | 対象 | BGP 伝搬 | 主なルート |
|:---|:---|:---|:---|
| `rt-spoke-to-fw` | Spoke サブネット | **無効** | 0.0.0.0/0 → Firewall |
| `rt-gateway` | GatewaySubnet | **有効** | Spoke CIDR → Firewall |

- `rt-spoke-to-fw`: BGP 伝搬を無効にすることで、ExpressRoute から学習したルートではなく Firewall 経由を強制します
- `rt-gateway`: BGP を有効にしつつ、Spoke 宛の通信だけ Firewall に向けます

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

Azure Policy は「このサブスクリプション内では〇〇を許可/禁止/監査する」というルールを強制する仕組みです。
本構成では 3 層のポリシーライブラリを合成しています。

| Layer | ライブラリ | 説明 | URL |
| --- | --- | --- | --- |
| 1 | ALZ | MSが提供するAzure Landing Zoneの公式ポリシー群。ベストプラクティスに沿った300近くのポリシー割り当てを流用しています。| [ALZ](https://github.com/Azure/Azure-Landing-Zones-Library/tree/main/platform/alz) |
| 2 | AMBA | MSが提供するAzure Monitorのアラートを設定するための公式ポリシー群です。ベストプラクティスに沿ったアラート設定をAzureポリシーによって自動で実施することができます。 | [AMBA](https://github.com/Azure/Azure-Landing-Zones-Library/tree/main/platform/amba) |
| 3 | カスタム | 1,2層に加えて独自のカスタムポリシーやポリシー割り当てを定義することができます。 | なし |

![ポリシー 3 層アーキテクチャ](diagrams/readme-05-policy-3-layer.svg)

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

---

## サブスクリプション自動払い出し（Vending）

### 概要

新しいサブスクリプション（= ワークロード環境）を追加するとき、YAML ファイルを 1 つ置くだけで必要なネットワークリソースがすべて自動作成されます。
以下のドキュメントを参考に実装しています。

[参考：サブスクリプションの自動販売の実装ガイダンス](https://learn.microsoft.com/ja-jp/azure/architecture/landing-zones/subscription-vending)

### 手順
例として、bashスクリプトでサブスクリプションを払い出してみます。

```bash
# 1. テンプレートをコピー
cp subscriptions/templates/corp-template.yaml subscriptions/my-system.yaml

# 2. YAML を編集（サブスクリプション ID、IP 範囲等を記入）
vim subscriptions/my-system.yaml

# 3. デプロイ
terraform plan    # 何が作られるか確認
terraform apply   # 実際に作成
```

**Terraform コードの編集は一切不要です。** YAML を追加するだけで以下が自動作成されます。

### 自動作成されるリソース

![Subscription Vending 自動生成リソース](diagrams/readme-06-vending-resources.svg)

### YAML の書き方

```yaml
# subscriptions/my-system.yaml
display_name: "my-system"
subscription_id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
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

## azapi と azurerm の使い分け

本構成では意図的に `azapi` と `azurerm` を使い分けています。

### azapi を選択する 5 つの理由

| # | 理由 | 該当リソース | 説明 |
|:---:|:---|:---|:---|
| 1 | **retry ブロック** | DCR, DNS Zone, Peering, Policy | Azure API の一時的エラーに自動リトライ。`azurerm` にはこの機能がない |
| 2 | **クロスサブスクリプション** | Vending 全リソース | フルリソース ID で任意のサブスクリプションを操作。provider alias 不要 |
| 3 | **REST API body 直接渡し** | Policy 5 種類 | ALZ プロバイダーの JSON 出力をそのまま流し込める |
| 4 | **azurerm 未対応機能** | DCR (CT, SQL) | extension データソースが azurerm では未サポート |

### azurerm を選択する場合

| 理由 | 説明 |
|:---|:---|
| **コードの読みやすさ** | HCL ネイティブの属性定義は JSON body より直感的 |
| **plan の差分表示** | azurerm の方が属性レベルの差分が見やすい |
| **バリデーション** | azurerm はスキーマ検証が厳密 |
| **ライフサイクル管理** | `create_before_destroy` 等のメタ引数が利用しやすい |

### 判断フローチャート

| 判断条件 | → | 選択 |
|:---|:---:|:---|
| リトライが必要？ | **Yes** | → `azapi` |
| クロスサブスクリプション？ | **Yes** | → `azapi` |
| ALZ JSON をそのまま流す？ | **Yes** | → `azapi` |
| azurerm で機能サポート？ | **No** | → `azapi` |
| 上記すべて No | — | → `azurerm` |

---

## リトライメカニズム一覧

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
| Role Definitions | `NotFound` | 15s | 120s | MG 伝搬遅延 |
| Vending Subnets | `AnotherOperationInProgress` | 10s | 60s | VNet 操作競合 |
| Vending Spoke→Hub | `RemoteVnetHasNoGateways` | 30s | 300s | ER Gateway 未完了 |
| Vending Hub→Spoke | `AnotherOperationInProgress` | 30s | 300s | VNet 操作競合 |

### なぜリトライが必要なのか

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

---

## デプロイ依存チェーン

`terraform apply` 実行時、リソースは以下の順序で作成されます。
並行実行可能なものは同時に作成され、依存関係のあるものは順序が保証されます。

![デプロイ依存チェーン（4 フェーズ）](diagrams/readme-07-deploy-dependency-chain.svg)

### ボトルネック

**ER Gateway のプロビジョニング** が最大のボトルネックで、約 25〜30 分かかります。
他のリソースは並行して作成されるため、全体の所要時間は ER Gateway + α（約 30〜35 分）です。

---

## 前提条件

| 要件 | 詳細 |
|:---|:---|
| **Azure サブスクリプション** | 4 つ（Management, Connectivity, Identity, Security） |
| **Terraform** | >= 1.9（推奨: 1.12+） |
| **認証** | `az login` または サービスプリンシパル / マネージド ID |
| **権限** | テナントルートで Owner または User Access Administrator + Contributor |
| **Azure Storage Account** | Terraform state backend 用（本番環境。テストはローカル state 可） |

---

## セットアップ手順

### 1. 設定ファイルの準備

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

hub_virtual_networks = {
  primary = {
    name          = "vnet-hub-japaneast"
    location      = "japaneast"
    address_space = ["10.0.0.0/16"]
    subnets = {
      firewall         = { address_prefix = "10.0.1.0/26" }
      firewall_mgmt    = { address_prefix = "10.0.1.64/26" }
      bastion          = { address_prefix = "10.0.1.128/26" }
      gateway          = { address_prefix = "10.0.2.0/27" }
    }
    express_route = {
      name                  = "er-japaneast"
      peering_location      = "Tokyo"
      service_provider_name = "Equinix"
      bandwidth_in_mbps     = 50
    }
  }
}
```

### 2. 初期化

```bash
# ローカル state（テスト用）
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
terraform plan -out=tfplan    # 作成されるリソースを確認（935 リソース程度）
terraform apply tfplan         # デプロイ実行（約 30〜35 分）
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

本リポジトリでは 4 つの GitHub Actions ワークフローでインフラのライフサイクルを管理します。

| ワークフロー | ファイル | トリガー | 概要 |
|:---|:---|:---|:---|
| **Terraform CI** | `ci.yaml` | PR → main | validate + plan、結果を PR コメントに貼付 |
| **Terraform CD** | `cd.yaml` | push main / 手動 | apply（自動）または destroy（手動選択） |
| **Drift Detection** | `drift-detection.yaml` | 毎日 09:00 JST / 手動 | state と実環境の差分を検知し Issue 管理 |
| **Dependency Check** | `dependency-check.yaml` | PR（lock/provider 変更時）/ 手動 | lock file 整合性 + provider バージョン検証 |

### デプロイフロー

```
feature ブランチ
│
├── PR 作成 ─────────────→ CI: terraform validate + plan（PR コメントに結果貼付）
│                          └─ *.lock.hcl 変更時 → Dependency Check も実行
│
├── レビュー承認 + CI 成功 → マージ可能
│
└── main マージ ─────────→ CD: terraform apply（自動デプロイ）

手動実行（workflow_dispatch）
├── action: apply  → CD: terraform apply
└── action: destroy → CD: terraform destroy
```

### 必要な GitHub Secrets

| Secret | 説明 |
|:---|:---|
| `AZURE_CLIENT_ID` | ユーザーマネージドIDのクライアント ID |
| `AZURE_TENANT_ID` | Azure AD テナント ID |
| `AZURE_SUBSCRIPTION_ID` | state backend 用サブスクリプション ID |
| `BACKEND_RESOURCE_GROUP` | state backend のリソースグループ名 |
| `BACKEND_STORAGE_ACCOUNT` | state backend のストレージアカウント名 |
| `BACKEND_CONTAINER` | state backend のコンテナ名 |

### OIDC 認証の設定

GitHub Actions から Azure への認証には OIDC（OpenID Connect）を使用します：

1. Azure にユーザーマネージドIDを作成
2. フェデレーション資格情報を追加（GitHub リポジトリ + ブランチを指定）
3. ユーザーマネージドIDに適切なロール（Owner）を付与
4. 上記の Secrets を GitHub リポジトリに設定

### ブランチ保護

`main` ブランチには以下の保護ルールが設定されています：

- 直接プッシュ禁止（PR 必須）
- CI（`Validate & Plan`）の成功必須
- 指定レビュアーの承認必須

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

Terraform プロバイダー（azurerm, azapi, alz, time）のバージョンを自動追跡し、更新 PR を管理します。

### Dependabot

GitHub Dependabot が `terraform.tf` の `required_providers` と `.terraform.lock.hcl` を週次でスキャンし、新バージョンがある場合は自動で PR を作成します。

| 設定 | 値 |
|:---|:---|
| スキャン頻度 | 毎週月曜 09:00 JST |
| 対象 | Terraform プロバイダー |
| ラベル | `dependencies`, `terraform` |
| レビュアー | 自動アサイン |
| 同時 PR 上限 | 5 |

### Dependency Check ワークフロー

Dependabot PR や手動のプロバイダー変更時に、lock file の整合性と互換性を自動検証します。

```
Dependabot → バージョン更新 PR 自動作成
                 ↓
        CI（plan 確認）+ Dependency Check（lock file 検証）
                 ↓
        レビュー → マージ → CD apply
```

- `terraform providers lock` で lock file の整合性を検証
- `terraform validate` で構文互換性を確認
- 現在の provider バージョンを PR コメントにレポート
- lock file に差分がある場合は警告を表示

---

## よくある質問

### Q: `terraform apply` が途中で失敗した場合は？

すべてのリトライ可能なエラーは `azapi` の `retry` ブロックで自動処理されます。
万が一失敗した場合は、そのまま再度 `terraform apply` を実行してください。
Terraform は state に記録済みのリソースをスキップし、未作成のリソースのみ作成します。（冪等）

### Q: 935 リソースもあるが plan が遅くないか？

`terraform plan` は約 5〜8 分かかります。これは Azure API への問い合わせが多いためです。

### Q: ER Gateway なしで使えるか？

はい。`terraform.tfvars` の `hub_virtual_networks` から `express_route` ブロックを削除し、
関連する ER リソースを `network-hub.tf` からコメントアウトしてください。
この場合、Spoke VNet で `use_hub_gateway: false` に設定する必要があります。

### Q: 既存のサブスクリプションを Landing Zone に追加できるか？

はい。`subscriptions/` に YAML ファイルを置き、既存サブスクリプションの ID を記入するだけです。
既にリソースがある場合、Terraform は YAML に定義されたリソースのみ追加で作成します。
