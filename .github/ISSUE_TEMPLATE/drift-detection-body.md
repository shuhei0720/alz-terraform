## 🔍 構成ドリフトを検知しました

Terraform の state と実際の Azure インフラストラクチャに差分があります。
手動変更、Azure 側の自動更新、またはコード外からの操作が原因の可能性があります。

---

### ⚠️ ドリフトが意味すること

ドリフトは「Terraform が管理している状態」と「実際の Azure リソースの状態」が不一致であることを示します。
放置すると以下のリスクがあります:

- 次回の `terraform apply` で **意図しないリソース変更・削除** が発生する
- **セキュリティ設定**（NSG ルール、Firewall ポリシー等）が想定と異なる状態になっている可能性
- **コンプライアンス違反** の原因となる場合がある

---

### Plan 出力

<details><summary>クリックして展開</summary>

```
${PLAN_OUTPUT}
```

</details>

---

### 🔎 よくあるドリフトの原因

| 原因 | 例 | 対処 |
|------|-----|------|
| Azure Portal からの手動変更 | タグの追加、NSG ルール変更 | Terraform コードに反映するか、手動変更を元に戻す |
| Azure 側の自動更新 | プラットフォームによるプロパティ追加 | `ignore_changes` で除外を検討 |
| 別の IaC ツール / スクリプト | ARM テンプレート、Azure CLI | 管理の一元化を検討 |
| Terraform の `ignore_changes` 漏れ | Spoke VNet の body 変更 | `subscription-vending.tf` の委任モデルを確認 |
| AMBA タグドリフト | `_deployed_by_amba = True` タグ | `amba_` archetype override でタグ設定を確認 |

---

### 📋 対処手順（Step by Step）

#### Step 1: plan 出力を読み、ドリフトの内容を特定

上の plan 出力を開き、**変更されるリソース** と **変更内容** を確認してください。
特に以下のリソースに注目:

- `azurerm_firewall_policy_rule_collection_group` — Firewall ルール
- `azurerm_route_table` / `azurerm_route` — ルーティング
- `azurerm_network_security_group` — NSG
- `azurerm_private_dns_zone_virtual_network_link` — DNS リンク
- `azapi_resource` — サブスクリプション内 Spoke リソース

#### Step 2: 原因に応じた対処を選択

**A. 意図した変更の場合（コードに反映すべき）:**

```bash
git checkout main && git pull
git checkout -b fix/drift-reconcile
# Terraform コードを修正して差分を反映
terraform plan  # 差分が解消されたことを確認
git add -A && git commit -m "fix: reconcile drift detected on ${DETECTED_AT}"
git push -u origin fix/drift-reconcile
# PR を作成 → CI 確認 → マージ
```

**B. 意図しない変更の場合（Azure 側を元に戻すべき）:**

```bash
# plan を確認し、apply で Terraform の状態に戻す
terraform plan -out=tfplan
# plan 内容を慎重に確認した上で
terraform apply tfplan
```

> ⚠️ `terraform apply` は本番環境に直接影響します。**必ず plan を確認してから実行**してください。

**C. 一時的な差分の場合（無視してよい）:**

Azure プラットフォームによる自動プロパティ追加など、一時的な差分は次回の検知で自動クローズされます。
繰り返し検知される場合は `ignore_changes` の追加を検討してください。

#### Step 3: 解消確認

ドリフトが解消されると、次回のスケジュール実行（毎日 09:00 JST）で自動的にこの Issue がクローズされます。
すぐに確認したい場合は [Drift Detection ワークフロー](${RUN_URL}/../) を手動実行してください。

---

### 📎 参考リンク

- [Terraform: Managing Drift](https://developer.hashicorp.com/terraform/tutorials/state/resource-drift)
- [subscription-vending.tf の委任モデル](../blob/main/subscription-vending.tf) — Spoke リソースの `ignore_changes` 設計
- [README: ドリフト検知ワークフロー](../blob/main/README.md)

---

*検知日時: ${DETECTED_AT}*
*Run: ${RUN_URL}*
