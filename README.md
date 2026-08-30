# codetrain-devenv

CodeTrain のローカル開発環境。`compose.yaml` / `scripts/` を持つ。
リポジトリを分けると `compose.yaml` がどのアプリにも属さなくなるため、devenv が所有する
（[Document/REPOSITORIES.md](../Document/REPOSITORIES.md) §2.2）。

設計の根拠は [Document/LOCAL_DEV.md](../Document/LOCAL_DEV.md)。**先にそちらを読むこと。**

## 起動

```bash
cp .env.example .env
docker compose up -d
```

これだけで、**マイグレーション・シード投入・Ministack の初期化まで終わった状態**になる。

```bash
curl -sS http://localhost:8080/healthz     # => {"status":"ok","db":"ok"}
curl -sS http://localhost:8080/v1/skills
curl -sS -H "X-Dev-User: seed-user-01" http://localhost:8080/v1/me
```

レビュー画面（admin）は compose の外。**別ターミナル**で起動する。

```bash
cp ../codetrain-admin/.env.local.example ../codetrain-admin/.env.local
make dev-admin        # ホストで next dev。フォアグラウンドで動き続ける
```

## 操作は素の docker compose

**profile も make ラッパも使わない。** フラグなしの `docker compose` がそのまま効く。

| やりたいこと | コマンド |
| --- | --- |
| 起動（初期化込み） | `docker compose up -d` |
| Dockerfile を変えた後の再ビルド | `docker compose up -d --build` |
| 停止（データは残る） | `docker compose down` |
| 停止してボリュームごと破棄 | `docker compose down -v` |
| 状態 | `docker compose ps` |
| ログ | `docker compose logs -f api` |
| 再起動 | `docker compose restart api` |
| DB に入る | `docker compose exec postgres psql -U codetrain -d codetrain` |
| シードだけ流し直す | `docker compose run --rm db-init seed` |
| マイグレーションを1つ戻す | `docker compose run --rm db-init down 1` |
| up → down -all → up の往復検証 | `docker compose run --rm db-init redo` |
| 現在のマイグレーション版 | `docker compose run --rm db-init version` |
| Ministack を初期化し直す | `docker compose run --rm aws-init` |
| テスト（ローカルと同じ条件） | `docker compose run --rm --no-deps api go test -tags dev_auth ./...` |
| テスト（本番と同じ条件） | `docker compose run --rm --no-deps api go test ./...` |
| 静的解析 | `docker compose run --rm --no-deps api go vet -tags dev_auth ./...` |
| 整形 | `docker compose run --rm --no-deps api gofmt -l cmd internal` |
| DB だけ作り直す | `docker compose rm -sf postgres && docker volume rm codetrain_pgdata && docker compose up -d` |

`make` に残しているのは **compose で表現できない2つ**だけ。

| コマンド | 内容 |
| --- | --- |
| `make dev-admin` | ホストで admin を起動（`.nvmrc` の Node + `next dev -H 0.0.0.0`） |
| `make doctor` | 環境診断（docker / 隣接リポジトリ / `.env` / ポート / バージョン整合） |

## サービス構成

| service | 実行形態 | ポート | 備考 |
| --- | --- | --- | --- |
| `postgres` | 常駐 | 5432（`.env` の `POSTGRES_PORT`） | 本番の Aurora とメジャーを揃える |
| `ministack` | 常駐 | 4566 | S3 / Cognito。S3 は永続化 |
| `aws-init` | **ワンショット** | — | S3 バケット・Cognito を作る。up のたびに走る（冪等） |
| `db-init` | **ワンショット** | — | マイグレーション + シード。up のたびに走る（冪等） |
| `api` | 常駐 | 8080 | Go + Echo。air でホットリロード。初期化2つの完了を待って起動 |
| `adminer` | 常駐 | 8081 | DB 閲覧 |
| `admin` | **compose 外** | 3000 | WSL ホストの `next dev`（`make dev-admin`） |

ワンショットの2つは `exited (0)` になるのが正常。`docker compose ps -a` で確認できる。

**profiles は使わない。** profile で絞ると依存先（postgres など）まで「未定義」扱いになり、
`depends_on` が壊れるため。Track A（pipeline / llm-proxy / sandbox-runner）に着手するときは、
profile ではなく `compose.lab.yaml` を追加して重ねる。

```bash
docker compose -f compose.yaml -f compose.lab.yaml up -d
```

こうすれば、pipeline を持っていない人の `docker compose up -d` は Track B だけを起動する。

## ポートと Windows 境界

Windows 側との境界を越えるのは **`api`(8080) と `admin`(3000) の2つだけ**。
経路が通らないときは LOCAL_DEV.md §2.2 / §11 を見る。ミラーネットワークモードが第一選択で、
使えない場合は管理者 PowerShell で `scripts/win/portproxy.ps1` を実行する。

ポートが他のプロセスと衝突する場合は `.env` で変更する（`make doctor` が検出する）。

## Ministack について（実測メモ）

- **Cognito は使える。** User Pool / App Client / ユーザー作成・JWKS 公開・
  `admin-initiate-auth` によるトークン発行まで動き、`AUTH_MODE=cognito` で
  本番と同じ検証パスを通せることを確認済み（OPEN_ISSUES D-3）。
- **Cognito の状態は永続化されない。** コンテナを作り直すと User Pool ID が変わる。
  そのため `aws-init` が `up` のたびに走り直し、`.generated/cognito.env` を更新する。
  `AUTH_MODE=cognito` を使うときは、そのたびに `.env` の `COGNITO_*` を貼り直すこと。
- **S3 は永続化している**（`S3_PERSIST=1` + 名前付きボリューム）。
- `COGNITO_JWKS_URL` は **api コンテナから見た URL**（`http://ministack:4566/...`）。
  ホストの `localhost:4566` を書くとコンテナ内から解決できない。

## いま作られていないもの

- **Track A** — `compose.lab.yaml` と `codetrain-pipeline`（LOCAL_DEV.md §6・§7）。
- **CI ワークフロー** — 各リポジトリを GitHub に push してから追加する。
