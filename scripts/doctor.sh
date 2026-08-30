#!/usr/bin/env bash
# make doctor — ローカル環境の診断（LOCAL_DEV.md §11）。
#
# ここで見るのは「詰まりどころ」として文書化されているもの:
#   * Docker が sudo なしで動くか
#   * 隣接リポジトリが揃っているか / WSL のネイティブ FS にあるか（/mnt/c は遅い）
#   * .env があるか
#   * ポートが他のプロセスに取られていないか
#   * Dockerfile のベースイメージと .go-version がズレていないか（§9.2）
#   * admin 側の Node / .env.local
#
# Windows 側の Flutter / Android SDK は WSL から見えないため対象外（§9.2）。
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"

ok=0; ng=0; warn=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; ok=$((ok+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; ng=$((ng+1)); }
note() { printf '  \033[33m!\033[0m %s\n' "$*"; warn=$((warn+1)); }

echo "== ツールチェーン"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    pass "docker $(docker --version | sed 's/Docker version //;s/,.*//')（sudo なしで実行できます）"
  else
    fail "docker が実行できません（デーモン未起動、または権限がありません）"
  fi
else
  fail "docker が見つかりません"
fi

if docker compose version >/dev/null 2>&1; then
  pass "docker compose $(docker compose version --short)"
else
  fail "docker compose v2 が見つかりません"
fi

# ホストの Go は補助用途。無くても 1〜4 の検証は成立する（§13-11）。
if command -v go >/dev/null 2>&1; then
  note "ホストに Go $(go version | awk '{print $3}') があります（補助用途。ビルドはコンテナが正）"
else
  note "ホストに Go はありません（ビルドはコンテナで完結するため問題ありません）"
fi

echo
echo "== リポジトリの配置"
case "$ROOT" in
  /mnt/[a-z]/*)
    fail "リポジトリが $ROOT にあります。9P 経由は遅く go build とホットリロードが実用になりません（§11）" ;;
  *)
    pass "WSL のネイティブ FS にあります: $ROOT" ;;
esac

for r in codetrain-core codetrain-api codetrain-admin; do
  if [ -d "$ROOT/$r" ]; then pass "$r"; else fail "$r がありません"; fi
done
[ -d "$ROOT/codetrain-pipeline" ] \
  && pass "codetrain-pipeline（Track A）" \
  || note "codetrain-pipeline はありません（Track A を触らないなら不要）"

echo
echo "== 設定ファイル"
[ -f .env ] && pass ".env" || fail ".env がありません（cp .env.example .env）"
if [ -f "$ROOT/codetrain-admin/.env.local" ]; then
  pass "codetrain-admin/.env.local"
else
  fail "codetrain-admin/.env.local がありません（cp .env.local.example .env.local）"
fi

echo
echo "== Go のバージョン整合（§9.2）"
# 正は Dockerfile のベースイメージ。.go-version はホストの補助用途だが、
# ズレていると gopls の挙動がコンテナと食い違うため揃える。
for r in codetrain-api codetrain-core; do
  dockerfile="$ROOT/$r/Dockerfile.dev"
  [ -f "$dockerfile" ] || dockerfile="$ROOT/$r/Dockerfile"
  gv_file="$ROOT/$r/.go-version"
  [ -f "$gv_file" ] || continue
  gv="$(tr -d '[:space:]' < "$gv_file")"
  if [ -f "$dockerfile" ]; then
    base="$(sed -n 's/^FROM golang:\([0-9.]*\).*/\1/p' "$dockerfile" | head -1)"
    if [ -z "$base" ]; then
      note "$r: Dockerfile から golang のバージョンを読めませんでした"
    elif [[ "$gv" == "$base"* ]]; then
      pass "$r: Dockerfile=golang:$base / .go-version=$gv"
    else
      fail "$r: Dockerfile=golang:$base と .go-version=$gv がズレています"
    fi
  else
    note "$r: .go-version=$gv（Dockerfile なし。ビルドは利用側のイメージが決めます）"
  fi
done

echo
echo "== Node（admin はホスト実行）"
if [ -f "$ROOT/codetrain-admin/.nvmrc" ]; then
  want="$(tr -d '[:space:]' < "$ROOT/codetrain-admin/.nvmrc")"
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    have="$(bash -lc "source \$HOME/.nvm/nvm.sh >/dev/null 2>&1 && nvm version $want" 2>/dev/null)"
    if [ -n "$have" ] && [ "$have" != "N/A" ]; then
      pass "nvm に .nvmrc の版があります（$want → $have）"
    else
      fail "nvm に Node $want がありません（cd codetrain-admin && nvm install）"
    fi
  else
    fail "nvm が見つかりません（admin はホストで next dev を動かすため必須）"
  fi
fi
[ -d "$ROOT/codetrain-admin/node_modules" ] \
  && pass "codetrain-admin/node_modules" \
  || note "codetrain-admin で npm ci がまだです（make dev-admin が自動で実行します）"

echo
echo "== ポート"
# 使いたいポートを、このプロジェクト以外のプロセスが握っていないか確認する。
#
# 判定の順番が大事: 先に「自分のコンテナが公開しているポートか」を見る。
# docker-proxy は root プロセスなので、一般ユーザーの ss にはプロセス名が見えず、
# リスナーの正体をプロセス名から判別することはできない。
port_of() { sed -n "s/^$1=//p" .env 2>/dev/null | tail -1; }

# このプロジェクトのコンテナが公開しているポートの一覧（":<port>->" の形で並ぶ）
published="$(docker ps --filter label=com.docker.compose.project=codetrain \
              --format '{{.Ports}}' 2>/dev/null || true)"

check_port() {
  local name="$1" port="$2"
  [ -n "$port" ] || return 0

  if echo "$published" | grep -q ":$port->"; then
    pass "$name :$port は codetrain のコンテナが使用中"
    return 0
  fi

  local holder
  holder="$(ss -lntH "sport = :$port" 2>/dev/null | head -1)"
  if [ -z "$holder" ]; then
    pass "$name :$port は空いています"
  else
    fail "$name :$port を別のプロセスが使用中です。.env で変更してください（§11）"
    printf '        %s\n' "$holder"
  fi
}
check_port postgres  "$(port_of POSTGRES_PORT)"
check_port ministack "$(port_of MINISTACK_PORT)"
check_port api       "$(port_of API_PORT)"
check_port adminer   "$(port_of ADMINER_PORT)"
check_port admin     3000

echo
echo "== 結果: ok=$ok / 要対応=$ng / 注意=$warn"
[ "$ng" -eq 0 ]
