# mmt-img — 給 Codex／AI 助理的工作規則

<!-- ship:begin -->
## 上線流程（統一規則，2026-09-18）
- **git push 不等於上線。** 改完要上線，一律在 repo 根目錄跑：

```sh
bash scripts/ship.sh ship "commit 訊息"
```

- 這一條會：有改動就 commit → push main → 前置檢查 → 部署 → 驗證。只部署不碰 git 用 `bash scripts/ship.sh deploy`；加 `--dry` 只建置不上傳。
- 部署方式：沒有獨立部署步驟：push 到 main 即完成（或由 GitHub Actions／排程接手）。
- commit 作者信箱固定用 repo 的 local 設定（127401827+TE-CHUN-LIU@users.noreply.github.com），commit 時不要另指定 email。
- 直接推 main，不開 PR。收尾跑 lint／測試；改 UI 要掃 320／390／430／768／1024／1440 六種寬度。對外文案不放 emoji，回覆用繁體中文（台灣）。
- 專案注意：IG 圖公開 URL 倉庫。
<!-- ship:end -->
