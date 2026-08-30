# CodeTrain ローカル開発環境の統一エントリポイント
# 設計: Document/LOCAL_DEV.md §9.1
#
# 方針:
#   * Go（api / migrate / test / lint）は**必ずコンテナ**で実行する
#   * admin(Next.js) だけは compose 外。make dev-admin がホストで next dev を起動する

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE ?= docker compose
REPO_ROOT := $(abspath $(CURDIR)/..)

# 隣接リポジトリ（REPOSITORIES.md §2.2 の横並びチェックアウト）
CORE_DIR  := $(REPO_ROOT)/codetrain-core
API_DIR   := $(REPO_ROOT)/codetrain-api
ADMIN_DIR := $(REPO_ROOT)/codetrain-admin

# make migrate / make seed は core の migrator を通す（LOCAL_DEV.md §10.2）
MIGRATOR := $(COMPOSE) --profile manual run --rm --no-TTY migrate

# .env から読む値（ホストから接続するときのポート表示などに使う）
POSTGRES_USER ?= $(shell sed -n 's/^POSTGRES_USER=//p' .env 2>/dev/null | tail -1)
POSTGRES_DB   ?= $(shell sed -n 's/^POSTGRES_DB=//p'   .env 2>/dev/null | tail -1)
POSTGRES_USER := $(if $(POSTGRES_USER),$(POSTGRES_USER),codetrain)
POSTGRES_DB   := $(if $(POSTGRES_DB),$(POSTGRES_DB),codetrain)

.PHONY: help
help: ## このヘルプを表示
	@echo "CodeTrain devenv — 使い方"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  初回: make bootstrap → cp .env.example .env → make up-core → make seed → make up-product"

# -----------------------------------------------------------------------------
# セットアップ
# -----------------------------------------------------------------------------

.PHONY: bootstrap
bootstrap: ## 必要なリポジトリが揃っているか確認（PROFILE=product|lab|all）
	@PROFILE=$${PROFILE:-product}; \
	echo "PROFILE=$$PROFILE で必要なリポジトリを確認します"; \
	case "$$PROFILE" in \
	  product) repos="codetrain-core codetrain-api codetrain-admin" ;; \
	  lab)     repos="codetrain-core codetrain-pipeline" ;; \
	  all)     repos="codetrain-core codetrain-api codetrain-admin codetrain-pipeline" ;; \
	  *) echo "PROFILE は product / lab / all のいずれかです" >&2; exit 2 ;; \
	esac; \
	missing=0; \
	for r in $$repos; do \
	  if [ -d "$(REPO_ROOT)/$$r" ]; then \
	    echo "  ok      $$r"; \
	  else \
	    echo "  missing $$r"; missing=1; \
	  fi; \
	done; \
	if [ $$missing -ne 0 ]; then \
	  echo; \
	  echo "未取得のリポジトリがあります。GitHub に push 済みなら以下で取得できます:"; \
	  echo "  (cd $(REPO_ROOT) && gh repo clone gabaison-2026-09/<repo>)"; \
	  exit 1; \
	fi; \
	if [ ! -f .env ]; then echo; echo "次: cp .env.example .env"; fi

.PHONY: setup-goprivate
setup-goprivate: ## private Go module（codetrain-core）参照のための設定
	@echo "codetrain-core はまだ GitHub に push されていないため、現在は"
	@echo "codetrain-api/go.mod の replace で隣のチェックアウトを参照しています。"
	@echo "core を公開してタグを打ったら、replace を外したうえで以下を実行してください。"
	@echo
	@echo "  go env -w GOPRIVATE=github.com/gabaison-2026-09/*"
	@echo "  git config --global url.\"git@github.com:\".insteadOf \"https://github.com/\""
	@echo
	@echo "コンテナ内のビルドにも認証が要ります（OPEN_ISSUES D-13 / D-24）。"

# -----------------------------------------------------------------------------
# 起動・停止
# -----------------------------------------------------------------------------

.PHONY: up-core
up-core: check-env ## 土台（postgres / ministack）を起動して Ministack を初期化
	$(COMPOSE) --profile core up -d
	@./scripts/bootstrap-ministack.sh

.PHONY: up-product
up-product: check-env ## Track B（api）を起動。admin は make dev-admin で別途
	$(COMPOSE) --profile product up -d --build
	@echo
	@echo "api: http://localhost:$${API_PORT:-8080}/healthz"
	@echo "レビュー画面を触るなら別ターミナルで: make dev-admin"

.PHONY: up-lab
up-lab: ## Track A を起動（codetrain-pipeline 着手後に有効）
	@echo "lab profile は codetrain-pipeline の着手時に compose.yaml へ追加します。" >&2
	@exit 1

.PHONY: up-all
up-all: check-env ## core + product をまとめて起動
	$(COMPOSE) --profile all up -d --build

.PHONY: up-tools
up-tools: check-env ## adminer（DB 閲覧）を起動
	$(COMPOSE) --profile tools up -d
	@echo "adminer: http://localhost:$${ADMINER_PORT:-8081}"

.PHONY: down
down: ## 停止（データは残る）。admin は Ctrl-C で別途止める
	$(COMPOSE) down --remove-orphans

.PHONY: ps
ps: ## 状態確認
	$(COMPOSE) ps

.PHONY: logs
logs: ## ログを追う（make logs SVC=api）
	$(COMPOSE) logs -f $(SVC)

# -----------------------------------------------------------------------------
# DB（すべて core の migrator 経由 — LOCAL_DEV.md §10.2）
# -----------------------------------------------------------------------------

.PHONY: migrate
migrate: check-env ## マイグレーションを最新まで適用
	$(MIGRATOR) up

.PHONY: migrate-down
migrate-down: check-env ## マイグレーションを1つ戻す（make migrate-down N=2）
	$(MIGRATOR) down $(or $(N),1)

.PHONY: migrate-redo
migrate-redo: check-env ## up → down -all → up の往復検証（CI と同じ手順）
	$(MIGRATOR) redo

.PHONY: migrate-version
migrate-version: check-env ## 現在のマイグレーションバージョン
	$(MIGRATOR) version

.PHONY: seed
seed: check-env ## シード投入（内部で migrate も実行される）
	$(MIGRATOR) seed

.PHONY: reset-db
reset-db: check-env ## DB をボリュームごと作り直して migrate + seed
	$(COMPOSE) rm -sf postgres
	docker volume rm -f codetrain_pgdata
	$(COMPOSE) --profile core up -d postgres
	$(MIGRATOR) seed
	@echo "DB を作り直しました"

.PHONY: psql
psql: ## DB に入る
	$(COMPOSE) exec postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

# -----------------------------------------------------------------------------
# admin（唯一のホスト実行 — LOCAL_DEV.md §4.2）
# -----------------------------------------------------------------------------

.PHONY: dev-admin
dev-admin: ## ホストで admin を起動（.nvmrc の Node + next dev -H 0.0.0.0）
	@test -d "$(ADMIN_DIR)" || { echo "codetrain-admin がありません" >&2; exit 1; }
	@test -f "$(ADMIN_DIR)/.env.local" || { \
		echo "codetrain-admin/.env.local がありません。以下を実行してください:" >&2; \
		echo "  cp $(ADMIN_DIR)/.env.local.example $(ADMIN_DIR)/.env.local" >&2; exit 1; }
	@bash -lc 'set -e; \
		source "$$HOME/.nvm/nvm.sh"; \
		cd "$(ADMIN_DIR)"; \
		nvm use; \
		[ -d node_modules ] || npm ci; \
		npm run dev'

# -----------------------------------------------------------------------------
# テスト・静的解析（コンテナ内で実行 — ホストの goenv の状態に左右されない）
# -----------------------------------------------------------------------------

.PHONY: test
test: ## api / core のテスト（コンテナ内。開発ビルドと本番ビルドの両方）
	$(COMPOSE) --profile product run --rm --no-deps --no-TTY api sh -c '\
		echo "--- dev_auth あり（ローカルと同じ条件）" && go test -tags dev_auth ./... && \
		echo "--- dev_auth なし（本番と同じ条件）"     && go test ./...'

.PHONY: lint
lint: ## 静的解析（コンテナ内。開発ビルドと本番ビルドの両方を検査）
	$(COMPOSE) --profile product run --rm --no-deps --no-TTY api sh -c '\
		go vet -tags dev_auth ./... && \
		go vet ./... && \
		unformatted=$$(gofmt -l cmd internal) && \
		if [ -n "$$unformatted" ]; then \
			echo "gofmt されていないファイル:"; echo "$$unformatted"; exit 1; \
		fi'

# -----------------------------------------------------------------------------
# 診断
# -----------------------------------------------------------------------------

.PHONY: doctor
doctor: ## 環境診断
	@./scripts/doctor.sh

.PHONY: check-env
check-env:
	@test -f .env || { \
		echo ".env がありません。cp .env.example .env を実行してください" >&2; exit 1; }
