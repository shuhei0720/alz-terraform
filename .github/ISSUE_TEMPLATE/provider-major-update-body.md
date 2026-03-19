## Terraform プロバイダーのメジャーバージョン更新が検出されました

${UPDATES}

---

### ⚠️ メジャーバージョン更新について

メジャーバージョンの更新は **破壊的変更（Breaking Changes）** を含みます。
Dependabot は `~>` 制約の範囲内でしか更新できないため、手動対応が必要です。

想定されるリスク:
- **リソース属性の削除・名前変更** → `terraform plan` エラー
- **プロバイダー設定の変更** → `provider` ブロックの書き換え
- **リソース動作の変更** → 意図しないリソース再作成
- **非推奨機能の削除** → 既存コードの修正が必要

---

### 📋 更新手順

#### Step 1: リリースノートの確認

**必ず Upgrade Guide / Breaking Changes を確認してください。**

${CHANGELOG_LINKS}

#### Step 2: terraform.tf の制約を更新

```hcl
# 例: azurerm ~> 4.0 → ~> 5.0
version = "~> X.0"
```

#### Step 3: コード修正

リリースノートの Breaking Changes に従い、`.tf` ファイルを修正。

#### Step 4: ロックファイル更新とテスト

```bash
terraform init -upgrade
terraform plan
```

#### Step 5: PR 作成

変更内容をレビューし、CI が通ることを確認してからマージ。
