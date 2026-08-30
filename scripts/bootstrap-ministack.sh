#!/usr/bin/env bash
# Ministack 上のリソースを初期化する（LOCAL_DEV.md §4.2）。
#
#   * S3 バケット（raw code / 成果物の置き場）
#   * Cognito User Pool / App Client / テストユーザー
#
# **冪等**。何度実行してもエラーにならないこと（LOCAL_DEV.md §13-9）。
# compose の aws-init サービスとして `docker compose up -d` のたびに実行される。
# 単体で流し直したいときは:
#
#   docker compose run --rm aws-init
#
# 実行環境は amazon/aws-cli イメージの中。ホストに AWS CLI は要らない。
# 設定は compose の environment から受け取る（.env は読まない）。
set -euo pipefail

ENDPOINT="${AWS_ENDPOINT_URL:-http://ministack:4566}"
S3_BUCKET="${S3_BUCKET:-codetrain-local}"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
OUT_DIR="${OUT_DIR:-/out}"

POOL_NAME="codetrain-local"
CLIENT_NAME="codetrain-local-app"
TEST_USER="seed-user-01"
TEST_PASSWORD="${COGNITO_TEST_PASSWORD:-CodeTrain#Local1}"

log()  { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }

echo "Ministack を初期化します ($ENDPOINT)"

# --- 起動待ち ----------------------------------------------------------------
# compose の depends_on: service_healthy で待っているが、単体実行にも耐えるよう
# ここでも待つ。sts get-caller-identity は最も軽い疎通確認。
for i in $(seq 1 30); do
  if aws --endpoint-url "$ENDPOINT" sts get-caller-identity >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "Ministack が $ENDPOINT で応答しません" >&2
    exit 1
  fi
  sleep 1
done

# --- S3 ----------------------------------------------------------------------
# S3 はパススタイルアクセスで使う（LOCAL_DEV.md §4.2）。AWS CLI は
# エンドポイント指定時にパススタイルへ落ちるため、追加の設定は不要。
if aws --endpoint-url "$ENDPOINT" s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
  log "S3 バケット $S3_BUCKET は既にあります"
else
  aws --endpoint-url "$ENDPOINT" s3api create-bucket \
    --bucket "$S3_BUCKET" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null 2>&1 \
    || aws --endpoint-url "$ENDPOINT" s3api create-bucket --bucket "$S3_BUCKET" >/dev/null
  log "S3 バケット $S3_BUCKET を作成しました"
fi

# --- Cognito -----------------------------------------------------------------
# Ministack 1.5.3 で User Pool 作成・JWKS 公開・トークン発行まで動くことを実測済み
# （OPEN_ISSUES D-3）。ただし **Cognito の状態は永続化されない**ため、
# コンテナを作り直すと User Pool ID が変わる。だからこのスクリプトは up のたびに走る。
#
# 失敗しても致命傷にしない。AUTH_MODE の既定は dev（LOCAL_DEV.md §5.4）なので、
# Cognito が使えなくても開発は止まらない。
setup_cognito() {
  local pool_id client_id

  pool_id="$(aws --endpoint-url "$ENDPOINT" cognito-idp list-user-pools --max-results 60 2>/dev/null \
    | grep -B2 "\"$POOL_NAME\"" | sed -n 's/.*"Id": "\([^"]*\)".*/\1/p' | head -1 || true)"

  if [ -z "$pool_id" ]; then
    pool_id="$(aws --endpoint-url "$ENDPOINT" cognito-idp create-user-pool --pool-name "$POOL_NAME" 2>/dev/null \
      | sed -n 's/.*"Id": "\([^"]*\)".*/\1/p' | head -1 || true)"
    [ -n "$pool_id" ] && log "User Pool を作成しました: $pool_id"
  else
    log "User Pool は既にあります: $pool_id"
  fi
  [ -n "$pool_id" ] || return 1

  client_id="$(aws --endpoint-url "$ENDPOINT" cognito-idp list-user-pool-clients --user-pool-id "$pool_id" 2>/dev/null \
    | sed -n 's/.*"ClientId": "\([^"]*\)".*/\1/p' | head -1 || true)"
  if [ -z "$client_id" ]; then
    client_id="$(aws --endpoint-url "$ENDPOINT" cognito-idp create-user-pool-client \
      --user-pool-id "$pool_id" --client-name "$CLIENT_NAME" \
      --explicit-auth-flows ALLOW_ADMIN_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH 2>/dev/null \
      | sed -n 's/.*"ClientId": "\([^"]*\)".*/\1/p' | head -1 || true)"
    [ -n "$client_id" ] && log "App Client を作成しました: $client_id"
  else
    log "App Client は既にあります: $client_id"
  fi
  [ -n "$client_id" ] || return 1

  # テストユーザー。既にいれば作らない。
  if aws --endpoint-url "$ENDPOINT" cognito-idp admin-get-user \
       --user-pool-id "$pool_id" --username "$TEST_USER" >/dev/null 2>&1; then
    log "テストユーザー $TEST_USER は既にあります"
  else
    aws --endpoint-url "$ENDPOINT" cognito-idp admin-create-user \
      --user-pool-id "$pool_id" --username "$TEST_USER" \
      --message-action SUPPRESS >/dev/null 2>&1 || return 1
    aws --endpoint-url "$ENDPOINT" cognito-idp admin-set-user-password \
      --user-pool-id "$pool_id" --username "$TEST_USER" \
      --password "$TEST_PASSWORD" --permanent >/dev/null 2>&1 || true
    log "テストユーザー $TEST_USER を作成しました"
  fi

  # COGNITO_JWKS_URL は **api コンテナから見た URL**（compose のサービス名）。
  # ホストの localhost:4566 を書くと、コンテナ内から解決できない。
  mkdir -p "$OUT_DIR"
  cat > "$OUT_DIR/cognito.env" <<EOF
# scripts/bootstrap-ministack.sh が生成（Git 管理外）。
# AUTH_MODE=cognito を使うときは、この3行を .env にコピーする。
# **コンテナを作り直すと ID が変わる**ので、そのたびに貼り直すこと。
COGNITO_USER_POOL_ID=$pool_id
COGNITO_CLIENT_ID=$client_id
COGNITO_JWKS_URL=$ENDPOINT/$pool_id/.well-known/jwks.json

# 以下は動作確認用（.env にコピーする必要はない）。
COGNITO_TEST_USER=$TEST_USER
COGNITO_TEST_PASSWORD=$TEST_PASSWORD
EOF
  log "$OUT_DIR/cognito.env に出力しました"
  return 0
}

if ! setup_cognito; then
  warn "Cognito を初期化できませんでした。AUTH_MODE=dev（既定）なら開発は止まりません。→ OPEN_ISSUES D-3"
fi

echo "Ministack の初期化が完了しました"
