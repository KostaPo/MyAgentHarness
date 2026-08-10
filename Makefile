.PHONY: up down run run-open logs ps clean denied

# Поднять инфраструктуру (модель, БД-мост, прокси) без самого агента
up:
	docker compose up -d llama-cpp mcp-db egress-proxy

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

# Логи инфраструктурных сервисов
logs:
	docker compose logs -f llama-cpp mcp-db egress-proxy

# Список доменов, заблокированных squid (для расширения allowlist)
denied:
	docker compose exec egress-proxy \
		grep TCP_DENIED /var/log/squid/access.log 2>/dev/null | \
		awk '{print $$7}' | sed -E 's/:[0-9]+$$/''/' | sort -u