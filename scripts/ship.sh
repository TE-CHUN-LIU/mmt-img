#!/usr/bin/env bash
# 一鍵上線（Codex／Claude／人都用這支；全部專案同一份範本，只有下面設定區不同）
#   bash scripts/ship.sh ship "commit 訊息"   有改動就 commit → push main → 部署 → 驗證
#   bash scripts/ship.sh deploy                只部署目前 HEAD，不碰 git
#   加 --dry                                   走完檢查與建置但不上傳、不 push
# 有 package.json 的專案也可用 npm run ship / npm run deploy。
set -euo pipefail
cd "$(dirname "$0")/.."

# ───────── 專案設定（由 2026-09-18 統一產生，可手改） ─────────
MODE="push-only"            # vercel-prebuilt | vercel-cloud | custom | cloudflare | clasp | push-only
DOMAINS=""      # 正式網域（空白分隔），部署後逐一 alias＋curl 驗證
PRECHECK=""    # 上傳前要過的檢查指令（空＝不檢查）
DEPLOY_CMD=""  # MODE=custom/cloudflare 時實際執行的部署指令
ENV_FILES=".env .env.production .env.local"   # prebuilt 時把 NEXT_PUBLIC_*/VITE_* 從這些檔帶進 build（後者覆蓋前者）
# ─────────────────────────────────────────────────────────────

CMD="${1:-deploy}"; shift || true
DRY=0; MSG=()
for a in "$@"; do [ "$a" = "--dry" ] && DRY=1 || MSG+=("$a"); done
MODE="${SHIP_MODE:-$MODE}"
log(){ printf '\n▶ %s\n' "$*"; }
die(){ printf '✗ %s\n' "$*" >&2; exit 1; }

# 1. git：commit + push
if [ "$CMD" = "ship" ] && [ -d .git ]; then
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -q -m "${MSG[*]:-更新}" && echo "✓ commit: ${MSG[*]:-更新}"
  else
    echo "工作樹乾淨，跳過 commit"
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    [ $DRY = 1 ] && echo "(dry) 略過 push" || { git pull -q --rebase --autostash origin main; git push -q origin HEAD:main && echo "✓ push main"; }
  else
    echo "此 repo 沒有 origin，只 commit 不 push"
  fi
fi

# 2. 前置檢查
if [ -n "$PRECHECK" ]; then
  log "前置檢查：$PRECHECK"
  bash -c "$PRECHECK" || die "前置檢查沒過，先修好再上"
fi

# 3. 部署
verify(){
  [ -z "$DOMAINS" ] && return 0
  log "驗證正式網域"
  local fail=0
  for d in $DOMAINS; do
    code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 20 "https://$d" || echo 000)
    printf '  %s  https://%s\n' "$code" "$d"
    case "$code" in 200|301|302|308|401) ;; *) fail=1;; esac
  done
  [ $fail = 0 ] || die "有網域回應異常，請看上面"
}
alias_all(){  # $1 = deployment url
  for d in $DOMAINS; do
    vercel alias set "$1" "$d" >/dev/null 2>&1 && echo "  alias → $d" || echo "  alias $d 失敗（若是 *.vercel.app 預設網域可忽略）"
  done
}
vercel_env_fill(){
  # vercel pull 會把 sensitive 的 NEXT_PUBLIC_/VITE_ 拉成空字串 → 用本機 ENV_FILE 補回，補不齊就拒絕 build
  local f=.vercel/.env.production.local
  [ -f "$f" ] || return 0
  for ef in $ENV_FILES; do [ -f "$ef" ] && { set -a; . "./$ef"; set +a; }; done
  local missing=()
  while IFS='=' read -r k v; do
    case "$k" in NEXT_PUBLIC_*|VITE_*) ;; *) continue;; esac
    v="${v%\"}"; v="${v#\"}"
    if [ -z "$v" ]; then
      if [ -n "${!k:-}" ]; then
        python3 - "$f" "$k" "${!k}" <<'PY'
import sys,re
f,k,v=sys.argv[1:]; s=open(f).read()
s=re.sub(r'^%s=.*$'%re.escape(k), '%s="%s"'%(k,v), s, flags=re.M); open(f,'w').write(s)
PY
      else missing+=("$k"); fi
    fi
  done < <(grep -E '^(NEXT_PUBLIC_|VITE_)' "$f" || true)
  [ ${#missing[@]} = 0 ] || die "公開環境變數是空的、本機 $ENV_FILES 也沒有：${missing[*]}（prebuilt 會整站壞掉）"
  # 同一個 shell 再 export 一次，Next/Vite 建置時才吃得到
  set -a; . "./$f"; set +a
}

case "$MODE" in
  vercel-prebuilt)
    log "vercel pull（production 設定）"; vercel pull --yes --environment=production >/dev/null
    vercel_env_fill
    log "本機建置"; rm -rf .vercel/output; vercel build --prod >/tmp/ship-build.log 2>&1 || { tail -40 /tmp/ship-build.log; die "build 失敗"; }
    echo "✓ build 完成"
    [ $DRY = 1 ] && { echo "(dry) 不上傳"; exit 0; }
    log "上傳 prebuilt 到 production"
    URL=$(vercel deploy --prebuilt --prod --yes 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.vercel\.app' | tail -1)
    [ -n "$URL" ] || die "部署失敗，拿不到部署網址"
    echo "✓ 部署：$URL"; alias_all "$URL"; verify
    if [ -f .vercel/output/static/index.html ] && [ -n "$DOMAINS" ]; then
      first=${DOMAINS%% *}
      [ "$(md5 -q .vercel/output/static/index.html)" = "$(curl -sL "https://$first" | md5 -q)" ] && echo "✓ 正式站首頁＝本機 build（md5 一致）" || echo "  首頁 md5 不同（可能 CDN 換版中或含動態內容），30 秒後再看"
    fi
    ;;
  vercel-cloud)
    [ $DRY = 1 ] && { echo "(dry) 雲端模式不做本機建置，結束"; exit 0; }
    log "vercel deploy --prod（雲端建置）"
    URL=$(vercel deploy --prod --yes 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.vercel\.app' | tail -1)
    [ -n "$URL" ] || die "部署失敗；若被擋（UNKNOWN/Blocked），改跑：SHIP_MODE=vercel-prebuilt bash scripts/ship.sh deploy"
    echo "✓ 部署：$URL"; alias_all "$URL"; verify
    ;;
  custom|cloudflare)
    [ $DRY = 1 ] && { echo "(dry) 不執行：$DEPLOY_CMD"; exit 0; }
    log "部署：$DEPLOY_CMD"; bash -c "$DEPLOY_CMD"; verify
    ;;
  clasp)
    [ $DRY = 1 ] && { echo "(dry) 不 clasp push"; exit 0; }
    log "clasp push"; npx --yes @google/clasp push -f
    ;;
  push-only)
    echo "此專案沒有獨立部署步驟（push 到 main 即完成，或由 GitHub Actions／排程接手）"
    ;;
  *) die "未知 MODE=$MODE";;
esac
echo; echo "完成"
