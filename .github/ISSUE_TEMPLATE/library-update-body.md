## ポリシーライブラリの新バージョンが検出されました

${UPDATES}

---

### ⚠️ 重要: 更新前の注意事項

ALZ/AMBA ポリシーライブラリの更新は **ポリシー定義・割り当てに直接影響する** ため、慎重に行う必要があります。
以下のリスクを理解した上で作業してください。

- **ポリシー定義の削除・名前変更** → 既存の割り当てがエラーになる可能性
- **パラメータの変更** → `policy_default_values` や archetype override との不整合
- **新しいポリシー割り当ての追加** → 既存リソースに対する新たなコンプライアンス違反の検出
- **AMBA アラートルールの変更** → アラート発報条件の変化

---

### 📋 更新手順（Step by Step）

#### Step 1: リリースノートの確認

**必ず先にリリースノートを読み、Breaking Changes を確認してください。**

- [ALZ Library Releases](https://github.com/Azure/Azure-Landing-Zones-Library/releases)
- ALZ: `${CURRENT_ALZ}` → `${LATEST_ALZ}` の差分を確認
- AMBA: `${CURRENT_AMBA}` → `${LATEST_AMBA}` の差分を確認

特に以下を重点的にチェック:
- `BREAKING CHANGE` / `deprecated` の記載
- ポリシー定義の削除・リネーム
- パラメータのスキーマ変更
- 新規ポリシー割り当ての追加

#### Step 2: 作業ブランチの作成

```bash
git checkout main && git pull
git checkout -b update/alz-amba-library
```

#### Step 3: policy.tf の ref を更新

```hcl
# policy.tf — library_references
library_references = [
  {
    path = "platform/alz"
    ref  = "${LATEST_ALZ}"   # ← ${CURRENT_ALZ} から更新
    custom_url = null
  },
  {
    path = "platform/amba"
    ref  = "${LATEST_AMBA}"   # ← ${CURRENT_AMBA} から更新
    custom_url = null
  },
]
```

#### Step 4: Terraform の初期化と plan

```bash
terraform init -upgrade
terraform plan -out=tfplan 2>&1 | tee plan-output.txt
```

#### Step 5: plan 出力の精査（最重要）

plan 結果を **1 行ずつ確認** してください。特に以下に注意:

| チェック項目 | 確認ポイント |
|---|---|
| ポリシー定義の destroy | 既存割り当てが壊れないか |
| ポリシー割り当ての変更 | パラメータ値が意図通りか |
| ロール割り当ての変更 | ポリシーの remediation が正常に動くか |
| AMBA アラートルール | 閾値・条件の変更がないか |
| 追加されるリソース数 | 想定外に多くないか |

**想定外の destroy がある場合は、更新を中止してリリースノートを再確認してください。**

#### Step 6: PR の作成

```bash
git add policy.tf
git commit -m "chore: update ALZ/AMBA policy library refs"
git push -u origin update/alz-amba-library
```

#### Step 7: CI 確認 & レビュー

- CI（Terraform CI）が自動実行されます → **plan 結果を PR コメントで確認**
- Dependency Check も自動実行されます
- チームメンバーに **plan 差分のレビュー** を依頼
- 特にポリシー割り当ての変更は **2 人以上で確認** を推奨

#### Step 8: マージ & デプロイ監視

1. PR をマージ → CD（Terraform CD）が自動実行
2. **GitHub Actions のログをリアルタイムで監視**
3. Apply 完了後、Azure Portal で以下を確認:
   - 管理グループのポリシー割り当て一覧
   - コンプライアンスダッシュボード
   - AMBA のアラートルール（更新された場合）

#### Step 9: ロールバック手順（問題発生時）

```bash
git revert HEAD
git push
# CD が自動実行され、前バージョンの ref に戻る
```

---

### 📎 参考リンク

- [Azure Landing Zones Library](https://github.com/Azure/Azure-Landing-Zones-Library)
- [ALZ Terraform Module](https://github.com/Azure/terraform-azurerm-avm-ptn-alz)
- [AMBA Documentation](https://azure.github.io/azure-monitor-baseline-alerts/)
