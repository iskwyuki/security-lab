---
description: GitHub Issueの作成・更新・クローズ
trigger: "when the user asks to create, update, or close a GitHub issue"
disable-model-invocation: true
---

# Issue 管理スキル

## 引数

- 引数なし → 操作を選択（作成 / 更新 / クローズ）
- `create` / `作成` → 新規作成、`#番号` → 更新、`close #番号` → クローズ

## 原則

- 作成前に `gh issue list` で重複を確認する
- **完了条件のない Issue は作らない**。チェックボックス形式で検証可能な条件を必ず書く
- ラベル候補を提示して選んでもらう（未作成ラベルは作成を提案）
- 更新・クローズの前に `gh issue view` で現状を確認し、クローズ時は理由をコメントで残す

## テンプレート

```markdown
## 概要
{概要}

## 詳細
{詳細・背景}

## 完了条件
- [ ] {検証可能な条件}
```

## 過去事例

- 完了条件が「〜を改善する」のような非検証形だった Issue は、実装スコープがぶれて手戻りした。「〜が保存され、〜で再実行できる手順がある」のように**検証手段まで書く**と一発で収束する
