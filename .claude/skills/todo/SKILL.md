---
description: オープン中のGitHub Issueをカテゴリ・概要付きで一覧表示する
trigger: "when the user asks to see open issues, TODOs, or remaining tasks"
disable-model-invocation: true
---

# TODO スキル

## 原則

- `gh issue list --state open --limit 50 --json number,title,labels,body,assignees,milestone,createdAt` で取得し、**ラベルをカテゴリとして**分類する（複数ラベルは先頭、なしは「未分類」）
- 各行は `#番号 タイトル — 概要（body 先頭 1〜2 文、50 文字まで）` の形式。担当者・マイルストーンがあれば補足する
- 0 件なら「オープン中の Issue はありません」とだけ表示する

## 表示例

```
## TODO一覧（オープンIssue: N件）

### 🐛 bug
- #12 ログイン画面でエラーが発生する — ログインボタン押下時に500エラー

### ✨ enhancement
- #15 ダッシュボードにグラフ追加 — 月別売上の棒グラフを表示

### 未分類
- #3  READMEの更新 — セットアップ手順を最新化
```
