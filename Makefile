# CodeTrain devenv
#
# **日常操作は素の docker compose を使う。**（コマンドは README を参照）
#
#   docker compose up -d          起動（マイグレーション・シード・Ministack 初期化まで込み）
#   docker compose down           停止
#   docker compose logs -f api    ログ
#
# ここに残しているのは **compose で表現できない2つ**だけ:
#   dev-admin : admin はコンテナ外（WSL ホストの next dev）で、nvm の切り替えを伴う
#   doctor    : 環境診断スクリプト

SHELL := /bin/bash
.DEFAULT_GOAL := help

REPO_ROOT := $(abspath $(CURDIR)/..)
ADMIN_DIR := $(REPO_ROOT)/codetrain-admin

.PHONY: help
help: ## このヘルプを表示
	@echo "make のターゲットは2つだけです。他は docker compose を直接使ってください（README 参照）。"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  起動:   cp .env.example .env && docker compose up -d"
	@echo "  確認:   curl -sS http://localhost:8080/healthz"

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

.PHONY: doctor
doctor: ## 環境診断（docker / 隣接リポジトリ / .env / ポート / バージョン整合）
	@./scripts/doctor.sh
