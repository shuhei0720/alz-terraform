## 🔎 Dependency Check Report

<!-- BEGIN:provider-changed -->
### プロバイダー変更 (リスク: ${RISK_BADGE})

| Provider | 変更前 | 変更後 | 種別 |
|----------|--------|--------|------|
${PROVIDER_TABLE}
<!-- BEGIN:risk-high -->

> **⚠️ メジャーバージョン変更 / プロバイダー削除が含まれています。**
> Breaking Changes がないか、必ずリリースノートを確認してください。
<!-- END:risk-high -->
<!-- BEGIN:risk-medium -->

> **📝 マイナーバージョン変更**: 新機能追加やバグ修正が含まれる可能性があります。
> plan 結果に意図しない差分がないか確認してください。
<!-- END:risk-medium -->
<!-- END:provider-changed -->
<!-- BEGIN:provider-new -->
### 🆕 Lock file が新規追加されました

新しいプロバイダーの Lock file がこの PR で追加されました。
`terraform init` が正常に完了することを確認してください。
<!-- END:provider-new -->
<!-- BEGIN:provider-unchanged -->
### ✅ プロバイダーバージョンの変更なし
<!-- END:provider-unchanged -->

---

<!-- BEGIN:lock-ok -->
### ✅ Lock File 整合性: OK

Lock file のハッシュが再生成結果と一致しています。
<!-- END:lock-ok -->
<!-- BEGIN:lock-inconsistent -->
### ⚠️ Lock File の不整合あり

Lock file のハッシュが再生成と一致しません。
`terraform providers lock -platform=linux_amd64` を実行して再コミットしてください。

<!-- BEGIN:lock-diff -->
<details><summary>差分を表示</summary>

```diff
${LOCK_DIFF}
```

</details>
<!-- END:lock-diff -->
<!-- END:lock-inconsistent -->

<!-- BEGIN:checklist -->
---

### 📋 レビューチェックリスト

- [ ] リリースノート / CHANGELOG の確認
- [ ] `terraform plan` の差分に想定外の変更がないか
- [ ] `terraform.tf` のバージョン制約と lock file の整合性
<!-- BEGIN:checklist-high -->
- [ ] Breaking Changes の影響範囲を確認
- [ ] ロールバック手順を準備
<!-- END:checklist-high -->
<!-- END:checklist -->

---

<details><summary>📦 Provider Versions (詳細)</summary>

```json
${VERSIONS}
```

</details>

*Triggered by @${ACTOR}*
