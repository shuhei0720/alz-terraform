## Terraform プロバイダーのメジャーバージョン更新が検出されました

${UPDATES}

---

### ⚠️ 重要: 更新前の注意事項

メジャーバージョンの更新は **破壊的変更（Breaking Changes）** を含みます。
Dependabot は `~>` 制約の範囲内でしか自動 PR を作成できないため、手動対応が必要です。
以下のリスクを理解した上で作業してください。

- **リソース属性の削除・名前変更** → `terraform plan` エラー、既存コードの修正が必要
- **プロバイダー設定の変更** → `provider` ブロックの書き換え
- **リソース動作の変更** → 意図しないリソース再作成（destroy + create）
- **非推奨機能の削除** → deprecation warning → error への昇格
- **state の互換性** → 古い state 形式からの自動マイグレーション

---

### 📋 更新手順（Step by Step）

#### Step 1: リリースノートの確認

**必ず先に Upgrade Guide / Breaking Changes を確認してください。**

${CHANGELOG_LINKS}

特に以下を重点的にチェック:
- `BREAKING CHANGE` / `REMOVED` / `RENAMED` の記載
- リソーススキーマの変更（属性の追加・削除・型変更）
- `provider` ブロックの設定変更
- `data` ソースの返り値変更

#### Step 2: 作業ブランチの作成

```bash
git checkout main && git pull
git checkout -b update/provider-major-upgrade
```

#### Step 3: terraform.tf の制約を更新

```hcl
# 例: azurerm ~> 4.0 → ~> 5.0
required_providers {
  azurerm = {
    source  = "hashicorp/azurerm"
    version = "~> X.0"  # ← メジャーバージョンを更新
  }
}
```

#### Step 4: Breaking Changes に対応したコード修正

リリースノートの Breaking Changes に従い、`.tf` ファイルを修正してください。

| よくある変更パターン | 対処 |
|---|---|
| 属性名のリネーム | コード内の参照を一括置換 |
| 属性の削除 | 該当行を削除、代替属性に移行 |
| リソース名の変更 | `terraform state mv` で state を移行 |
| provider 設定の変更 | `terraform.tf` の provider ブロックを修正 |
| 新しい必須属性の追加 | デフォルト値を確認し設定 |

#### Step 5: ロックファイル更新

```bash
terraform init -upgrade
```

#### Step 6: PR の作成

```bash
git add -A
git commit -m "chore: upgrade <provider> to ~> X.0"
git push -u origin update/provider-major-upgrade
```

#### Step 7: CI 確認 & レビュー

- CI（Terraform CI）が自動実行されます → **plan 結果を PR コメントで確認**
- Dependency Check が SemVer リスク分析を PR にレポートします
- plan 結果を **1 行ずつ確認** してください。特に以下に注意:

| チェック項目 | 確認ポイント |
|---|---|
| リソースの destroy | 意図しない再作成がないか |
| state マイグレーション | 自動変換が正常に行われたか |
| 新しい属性のデフォルト値 | 想定通りの値が設定されるか |
| ignore_changes への影響 | 属性名変更でドリフトしないか |

**想定外の destroy がある場合は、マージを中止して Breaking Changes を再確認してください。**

#### Step 8: マージ & デプロイ監視

1. PR をマージ → CD（Terraform CD）が自動実行
2. **GitHub Actions のログをリアルタイムで監視**
3. Apply 完了後、Azure Portal でリソースの正常性を確認

#### Step 9: ロールバック手順（問題発生時）

```bash
git revert HEAD
git push
# CD が自動実行され、前バージョンの制約に戻る
# ただし state マイグレーションが行われた場合はダウングレード不可の場合あり
# その場合は terraform.tf のみ戻し、コードは新バージョンに合わせたまま維持
```

---

### 📎 参考リンク

- [Terraform Provider Registry](https://registry.terraform.io/)
- [azurerm Provider Upgrade Guides](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs#upgrading)
- [azapi Provider Releases](https://github.com/azure/azapi/releases)
- [alz Provider Releases](https://github.com/Azure/terraform-azurerm-avm-ptn-alz/releases)
