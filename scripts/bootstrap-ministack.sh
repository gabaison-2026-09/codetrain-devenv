#!/usr/bin/env bash
# Ministack 上のリソースを初期化する（LOCAL_DEV.md §4.2）。
#
#   * S3 バケット（raw code / 成果物の置き場）
#   * Cognito User Pool / App Client / テストユーザー（対応していれば）
#
# **冪等**。何度実行してもエラーにならないこと（LOCAL_DEV.md §13-9）。
#
# IaC（codetrain-infra）は本番専用と割り切り、ローカルの初期化はここに寄せる。
# AWS CLI はホストに入れず、コンテナから実行する。
set -euo pipefail

cd "$(dirname "$0")/.."

# .env を読む（値に空白を含まない前提の単純なパーサ）
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

MINISTACK_PORT="${MINISTACK_PORT:-4566}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
S3_BUCKET="${S3_BUCKET:-codetrain-local}"
ENDPOINT="http://localhost:${MINISTACK_PORT}"

AWS_CLI_IMAGE="${AWS_CLI_IMAGE:-amazon/aws-cli:2.32.9}"
GENERATED_DIR=".generated"

# ホストのループバック経由で Ministack に届くよう、host ネットワークで実行する。
aws_cli() {
  docker run --rm --network host \
    -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-dummy}" \
    -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-dummy}" \
    -e AWS_DEFAULT_REGION="$AWS_REGION" \
    -e AWS_PAGER="" \
    "$AWS_CLI_IMAGE" --endpoint-url "$ENDPOINT" "$@"
}

log()  { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }

echo "Ministack を初期化します ($ENDPOINT)"

# --- 起動待ち ----------------------------------------------------------------
for i in $(seq 1 30); do
  if curl -sS -o /dev/null "$ENDPOINT" 2>/dev/null; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "Ministack が $ENDPOINT で応答しません。make up-core が完了しているか確認してください" >&2
    exit 1
  fi
  sleep 1
done

# --- S3 ----------------------------------------------------------------------
# S3 はパススタイルアクセスで使う（LOCAL_DEV.md §4.2）。AWS CLI は既定で
# エンドポイント指定時にパススタイルへ落ちるため、追加の設定は不要。
if aws_cli s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
  log "S3 バケット $S3_BUCKET は既にあります"
else
  aws_cli s3api create-bucket \
    --bucket "$S3_BUCKET" \
    --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null 2>&1 \
    || aws_cli s3api create-bucket --bucket "$S3_BUCKET" >/dev/null
  log "S3 バケット $S3_BUCKET を作成しました"
fi

# --- Cognito -----------------------------------------------------------------
# 注意: Ministack の対応サービス一覧に **Cognito は含まれていない**（2026-08 時点）。
# LOCAL_DEV.md §1 の記述と食い違うため、ここでは失敗を致命傷にしない。
#
# AUTH_MODE の既定は dev（LOCAL_DEV.md §5.4）なので、Cognito が使えなくても
# 開発は止まらない。cognito モードの検証手段は OPEN_ISSUES D-3 で決着させる。
POOL_NAME="codetrain-local"
CLIENT_NAME="codetrain-local-app"
TEST_USER="seed-user-01"
TEST_PASSWORD="${COGNITO_TEST_PASSWORD:-CodeTrain#Local1}"

setup_cognito() {
  local pool_id client_id

  pool_id="$(aws_cli cognito-idp list-user-pools --max-results 60 2>/dev/null \
    | grep -B2 "\"$POOL_NAME\"" | sed -n 's/.*"Id": "\([^"]*\)".*/\1/p' | head -1 || true)"

  if [ -z "$pool_id" ]; then
    pool_id="$(aws_cli cognito-idp create-user-pool --pool-name "$POOL_NAME" 2>/dev/null \
      | sed -n 's/.*"Id": "\([^"]*\)".*/\1/p' | head -1 || true)"
    [ -n "$pool_id" ] && log "User Pool を作成しました: $pool_id"
  else
    log "User Pool は既にあります: $pool_id"
  fi
  [ -n "$pool_id" ] || return 1

  client_id="$(aws_cli cognito-idp list-user-pool-clients --user-pool-id "$pool_id" 2>/dev/null \
    | sed -n 's/.*"ClientId": "\([^"]*\)".*/\1/p' | head -1 || true)"
  if [ -z "$client_id" ]; then
    client_id="$(aws_cli cognito-idp create-user-pool-client \
      --user-pool-id "$pool_id" --client-name "$CLIENT_NAME" \
      --explicit-auth-flows ALLOW_ADMIN_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH 2>/dev/null \
      | sed -n 's/.*"ClientId": "\([^"]*\)".*/\1/p' | head -1 || true)"
    [ -n "$client_id" ] && log "App Client を作成しました: $client_id"
  else
    log "App Client は既にあります: $client_id"
  fi
  [ -n "$client_id" ] || return 1

  # テストユーザー。既にいれば作らない。
  if aws_cli cognito-idp admin-get-user \
       --user-pool-id "$pool_id" --username "$TEST_USER" >/dev/null 2>&1; then
    log "テストユーザー $TEST_USER は既にあります"
  else
    aws_cli cognito-idp admin-create-user \
      --user-pool-id "$pool_id" --username "$TEST_USER" \
      --message-action SUPPRESS >/dev/null 2>&1 || return 1
    aws_cli cognito-idp admin-set-user-password \
      --user-pool-id "$pool_id" --username "$TEST_USER" \
      --password "$TEST_PASSWORD" --permanent >/dev/null 2>&1 || true
    log "テストユーザー $TEST_USER を作成しました"
  fi

  mkdir -p "$GENERATED_DIR"
  # COGNITO_JWKS_URL は **api コンテナから見た URL**（compose のサービス名）。
  # ホストの localhost:4566 を書くと、コンテナ内から解決できない。
  cat > "$GENERATED_DIR/cognito.env" <<EOF
# scripts/bootstrap-ministack.sh が生成（Git 管理外）。
# AUTH_MODE=cognito を使うときは、この3行を .env にコピーする。
COGNITO_USER_POOL_ID=$pool_id
COGNITO_CLIENT_ID=$client_id
COGNITO_JWKS_URL=${AWS_ENDPOINT_URL:-http://ministack:4566}/$pool_id/.well-known/jwks.json

# 以下は動作確認用（.env にコピーする必要はない）。
# ホストから JWKS を見る場合の URL:
#   $ENDPOINT/$pool_id/.well-known/jwks.json
COGNITO_TEST_USER=$TEST_USER
COGNITO_TEST_PASSWORD=$TEST_PASSWORD
EOF
  log "$GENERATED_DIR/cognito.env に出力しました"
  return 0
}

if setup_cognito; then
  :
else
  warn "Ministack で Cognito を初期化できませんでした（未対応の可能性があります）。"
  warn "AUTH_MODE=dev（既定）のままなら開発は止まりません。→ OPEN_ISSUES D-3"
fi

echo "Ministack の初期化が完了しました"
