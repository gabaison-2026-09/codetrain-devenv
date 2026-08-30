# codetrain-devenv

CodeTrain のローカル開発環境。`compose.yaml` / `Makefile` / `scripts/` を持つ。
リポジトリを分けると `compose.yaml` がどのアプリにも属さなくなるため、devenv が所有する
（[Document/REPOSITORIES.md](../Document/REPOSITORIES.md) §2.2）。

設計の根拠は [Document/LOCAL_DEV.md](../Document/LOCAL_DEV.md)。**先にそちらを読むこと。**

## 前提

- **リポジトリは横並びにチェックアウトする。** compose の build context が相対パスで隣を指す。

  ```
  CodeTrain/
    Document/
    codetrain-devenv/   ← ここ
    codetrain-core/
    codetrain-api/
    codetrain-admin/
  ```

- Docker Engine を WSL2 のディストロ内に入れる（LOCAL_DEV.md §2.3）。
- **WSL のネイティブ FS に置く。** `/mnt/c/...` に置くと `go build` が実用にならない。
- Node は nvm（`codetrain-admin/.nvmrc`）。**Go はホストに不要**（コンテナで完結する）。

## 初回セットアップ

```bash
make bootstrap PROFILE=product   # 必要なリポジトリが揃っているか確認
cp .env.example .env             # 必要なら POSTGRES_PORT などを調整
make doctor                      # 環境診断
make up-core                     # postgres / ministack + Ministack 初期化
make seed                        # migrate してシード投入
make up-product                  # api（コンテナ）
```

確認:

```bash
curl -sS http://localhost:8080/healthz     # => {"status":"ok","db":"ok"}
curl -sS http://localhost:8080/v1/skills
curl -sS -H "X-Dev-User: seed-user-01" http://localhost:8080/v1/me
```

レビュー画面（admin）は**別ターミナル**で:

```bash
cp ../codetrain-admin/.env.local.example ../codetrain-admin/.env.local
make dev-admin        # ホストで next dev。フォアグラウンドで動き続ける
```

## 日常

| コマンド | 内容 |
| --- | --- |
| `make up-product` | api を起動（air でホットリロード。`make` の再実行は不要） |
| `make dev-admin` | **ホスト**で admin を起動（`make down` の対象外。Ctrl-C で停止） |
| `make logs SVC=api` / `make ps` / `make psql` | ログ / 状態 / DB |
| `make migrate` / `make seed` / `make reset-db` | DB（すべて core の migrator 経由） |
| `make migrate-redo` | up → down -all → up の往復検証 |
| `make test` / `make lint` | コンテナ内で実行（CI と同じ Go バージョン） |
| `make up-tools` | adminer（`http://localhost:8081`） |
| `make doctor` | 環境診断 |

## ポート

| サービス | 実行形態 | 既定ポート |
| --- | --- | --- |
| `api` | コンテナ | 8080 |
| `admin` | **ホストの `next dev`** | 3000 |
| `postgres` | コンテナ | 5432（`.env` の `POSTGRES_PORT` で変更可） |
| `ministack` | コンテナ | 4566 |
| `adminer` | コンテナ（tools） | 8081 |

Windows 側との境界を越えるのは **`api` と `admin` の2つだけ**。
経路が通らないときは LOCAL_DEV.md §2.2 / §11 を見る。ミラーネットワークモードが第一選択で、
使えない場合は管理者 PowerShell で `scripts/win/portproxy.ps1` を実行する。

## いま作られていないもの

- **Track A（`lab` profile）** — `pipeline` / `llm-proxy` / `sandbox-runner`。
  `codetrain-pipeline` に着手するとき compose.yaml に追加する（LOCAL_DEV.md §6・§7）。
- **CI ワークフロー** — 各リポジトリを GitHub に push してから追加する。

## Ministack について（実測メモ）

- **Cognito は使える。** User Pool / App Client / ユーザー作成・JWKS 公開・
  `admin-initiate-auth` によるトークン発行まで動き、`AUTH_MODE=cognito` で
  本番と同じ検証パスを通せることを確認済み（OPEN_ISSUES D-3）。
- **Cognito の状態は永続化されない。** コンテナを作り直すと User Pool ID が変わる。
  そのため `make up-core` は毎回 `scripts/bootstrap-ministack.sh` を流し直し、
  `.generated/cognito.env` を更新する。`AUTH_MODE=cognito` を使うときは、
  そのたびに `.env` の `COGNITO_*` を貼り直すこと。
- **S3 は永続化している**（`S3_PERSIST=1` + 名前付きボリューム）。
- `COGNITO_JWKS_URL` は **api コンテナから見た URL**（`http://ministack:4566/...`）。
  ホストの `localhost:4566` を書くとコンテナ内から解決できない。
