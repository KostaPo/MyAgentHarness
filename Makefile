.PHONY: up down run run-open logs ps clean denied net-check

# Поднять инфраструктуру (модель, БД-мост, прокси, поиск) без самого агента
up:
	docker compose up -d llama-cpp mcp-db egress-proxy searxng

# Остановить всё
down:
	docker compose down

# Полная остановка + удаление volumes (чистый старт)
clean:
	docker compose down -v

# Запуск агента в защищённом режиме (allowlist активен) — дефолт
run: up
	docker compose run --rm pi-agent

# Запуск агента с полным доступом в интернет (без allowlist)
run-open: up
	docker compose -f docker-compose.yml -f docker-compose.open-network.yml run --rm pi-agent

# Показать статус контейнеров
ps:
	docker compose ps

# Логи инфраструктурных сервисов (включая поиск)
logs:
	docker compose logs -f llama-cpp mcp-db egress-proxy searxng

# Только squid — удобно держать открытым в отдельном терминале во время сессии
proxy-log:
	docker compose logs -f egress-proxy

# Список доменов, заблокированных squid (для расширения allowlist)
denied:
	docker compose exec egress-proxy \
	   grep TCP_DENIED /var/log/squid/access.log 2>/dev/null | \
	   awk '{print $$7}' | sed -E 's/:[0-9]+$$/''/' | sort -u

# Список доменов, реально пропущенных squid (подтверждение, что MCP-вызовы идут через прокси)
allowed:
	docker compose exec egress-proxy \
	   grep TCP_TUNNEL /var/log/squid/access.log 2>/dev/null | \
	   awk '{print $$7}' | sed -E 's/:[0-9]+$$/''/' | sort -u

# Проверить, в каких сетях сейчас находится pi-agent (диагностика режима)
net-check:
	docker inspect pi-agent --format '{{range $$k,$$v := .NetworkSettings.Networks}}{{$$k}} {{end}}' 2>/dev/null || \
	   echo "pi-agent сейчас не запущен (это разовый контейнер, живёт только во время сессии)"

# Полная пересборка: снести volumes + образы + пересобрать заново
rebuild:
	docker compose down -v
	docker compose build --no-cache
	docker compose up -d llama-cpp mcp-db egress-proxy searxng

# То же самое + свежие версии готовых образов (dbhub, searxng, squid, llama.cpp)
rebuild-all:
	docker compose down -v
	docker compose pull
	docker compose build --no-cache
	docker compose up -d llama-cpp mcp-db egress-proxy searxng