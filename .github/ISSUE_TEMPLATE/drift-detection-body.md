## 🔍 構成ドリフトを検知しました

Terraform の state と実際の Azure インフラに差分があります。
手動変更やAzure側の自動更新が原因の可能性があります。

### Plan 出力
```
${PLAN_OUTPUT}
```

### 対処方法
- **意図した変更の場合**: Terraform コードを更新して PR を作成してください
- **意図しない変更の場合**: `terraform apply` で state と一致させてください
- **一時的な差分の場合**: 次回の検知で自動クローズされます

*検知日時: ${DETECTED_AT}*
*Run: ${RUN_URL}*
