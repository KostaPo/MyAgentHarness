# MyAgentHarness

Изолированная инфраструктура для запуска AI coding-агента (pi) поверх
любого локального проекта. Локальная LLM (llama.cpp) с фолбэком на
OpenRouter, доступ к БД через MCP, контролируемый выход в интернет,
поиск и чтение веб-страниц через open-source MCP-инструменты.

## Структура

```text
MyAgentHarness/
├── README.md
├── Makefile
├── .env                          # секреты, не коммитится
├── .env.example                  # шаблон .env
├── .gitignore
├── docker-compose.yml
├── docker-compose.open-network.yml
├── model/
│   └── llama-cpp.yml
├── mcp/
│   └── dbhub.toml
├── proxy/
│   ├── squid.conf
│   ├── allowlist-base.txt
│   └── searxng/
│       └── settings.yml
├── agents/
│   └── pi/
│       ├── Dockerfile
│       ├── entrypoint.sh
│       ├── models.json
│       └── mcp.json
└── shared/
    └── conventions/
        └── common.md              # монтируется агенту как AGENTS.md
```

## Что это делает

Агент работает в изолированном контейнере и не может:
- выйти за пределы папки проекта на диске
- запушить/запулить git (нет credentials)
- писать в БД (только чтение через readonly-роль)
- выйти в интернет мимо allowlist доменов (если явно не включён открытый режим)
- сохранить что-либо в самом контейнере между запусками (эфемерный, `--rm`)

## Схема

```text
                    LLM PROVIDER
                         │
           ┌─────────────┴─────────────┐
           ▼                           ▼
     llama-cpp (local)           OpenRouter (cloud)
           │                           │
           └─────────────┬─────────────┘
                          ▼
┌──────────────────────────────────────────────────────────────┐
│                        pi-agent                              │
│         read-only контейнер, --rm, без git credentials       │
│                                                                │
│   ┌───────────┐   ┌──────────┐   ┌────────┐   ┌────────────┐  │
│   │ filesystem│   │ mcp-db   │   │ search │   │   fetch    │  │
│   │ git, shell│   │ (DBHub)  │   │(SearXNG│   │(fetch-mcp) │  │
│   └─────┬─────┘   └────┬─────┘   │ + MCP) │   └─────┬──────┘  │
│         │              │         └───┬────┘         │         │
└─────────┼──────────────┼─────────────┼───────────────┼────────┘
          ▼              ▼             ▼               ▼
   /workspace       PostgreSQL    egress-proxy (squid, allowlist)
   (проект)         (read-only)         │
                                         ▼
                              разрешённые домены в интернете
```

## Границы изоляции

- **Файлы:** агент видит только `${PROJECT_PATH}` → `/workspace`, остальной диск хоста недоступен.
- **Эфемерность:** контейнер `--rm` + `read_only: true` — ничего не сохраняется между запусками, кроме явных volume.
- **Git:** нет SSH-ключей/credential helpers — push/pull физически невозможны.
- **БД:** двойная защита — readonly-роль в PostgreSQL И readonly-режим на уровне MCP-инструмента.
- **Сеть:** сеть `harness-net` объявлена `internal` (нет маршрута в интернет). Единственный выход — через `egress-proxy` (squid) с allowlist доменов. Работает на сетевом уровне — не обойти через смену инструмента (bash/curl и т.п.).

> `read_only: true` ограничивает файловую систему контейнера, но НЕ означает read-only доступ к PostgreSQL — это отдельная защита (см. выше).

## Секреты

Все секреты — в одном `.env` в корне (в `.gitignore`, никогда не коммитится). `.env.example` — шаблон с именами переменных без значений.

```
OPENROUTER_API_KEY=
DB_HOST=host.docker.internal
DB_PORT=5432
DB_NAME=
DB_AGENT_USER=
DB_AGENT_PASSWORD=
SEARXNG_SECRET=          # сгенерировать: openssl rand -hex 32
```

Открытый текст на диске — осознанный выбор для соло-разработки на доверенной машине. Для команды — заменить на Vault/SOPS.

`DB_*` привязаны к одному активному проекту — при смене проекта обновлять вручную.

## Быстрый старт

Один раз при клонировании:
```bash
cp .env.example .env
nano .env    # заполнить OPENROUTER_API_KEY, DB_*, SEARXNG_SECRET
```

Каждый рабочий запуск:
```bash
export PROJECT_PATH=/абсолютный/путь/до/проекта
make run
```

Внутри сессии pi — подключить нужные MCP:
```
/mcp connect postgres
/mcp connect search
/mcp connect fetch
```

Все команды:
```
make run          защищённый режим (allowlist активен) — дефолт
make run-open      полный доступ в интернет, без allowlist
make up            поднять инфраструктуру без агента
make down          остановить всё
make clean         остановить всё + удалить volumes (чистый старт)
make ps            статус контейнеров
make logs          логи llama-cpp, mcp-db, egress-proxy, searxng
make proxy-log     только squid, удобно держать открытым во время сессии
make denied        домены, заблокированные squid (кандидаты на allowlist)
make allowed       домены, реально пропущенные squid (подтверждение работы прокси)
make net-check     в каких сетях сейчас pi-agent (защищённый/открытый режим)
```

Никакого `chmod` или ручной настройки после `git clone` не требуется.

## БД проекта

Харнесс НЕ создаёт readonly-пользователя сам — это ответственность проекта. В init-скрипты проектного `docker-compose` (`docker-entrypoint-initdb.d`) добавить:

```sql
DO $$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'llm_agent') THEN
            CREATE ROLE llm_agent LOGIN PASSWORD 'llm_agent_password'
                NOCREATEDB NOCREATEROLE NOSUPERUSER NOBYPASSRLS
                CONNECTION LIMIT 5;
        END IF;
    END
$$;
GRANT pg_read_all_data TO llm_agent;
REVOKE ALL ON SCHEMA public FROM llm_agent;
```

Прописать креды в `.env` (`DB_AGENT_USER`, `DB_AGENT_PASSWORD`), убедиться что порт БД опубликован на хост (`ports: "5432:5432"` в проектном compose) — нужно для доступа через `host.docker.internal`.

## MCP-сервер БД (DBHub)

Единый сервис `mcp-db` (образ `bytebase/dbhub`), общий для всех агентов. Конфиг — `mcp/dbhub.toml`. Подключён к `harness-net` **и** `egress-net` — нужно для доступа к `host.docker.internal` (иначе у изолированной `harness-net` нет маршрута до хоста).

Нюансы:
- `readonly` задаётся на уровне `[[tools]]`, не `[[sources]]` — иначе DBHub отклонит конфиг с ошибкой.
- MCP-эндпоинт — `/mcp`, не корень.
- DBHub по умолчанию принимает запросы только с loopback — нужен явный `--allowed-hosts mcp-db,localhost,127.0.0.1`.

## Поиск и чтение веб-страниц (SearXNG + fetch-mcp)

Open-source стек без платных API-ключей:

- **search** — SearXNG (self-hosted метапоиск, движки: google, duckduckgo, bing, wikipedia, github). Отдельный контейнер `searxng`, MCP-обёртка `mcp-searxng` работает как stdio-процесс внутри `pi-agent` (не отдельный контейнер).
- **fetch** — `fetch-mcp`, тоже stdio-процесс внутри `pi-agent`, читает страницы порциями (без headless-браузера, легковесно).

Оба процесса автоматически наследуют `HTTP_PROXY`/`HTTPS_PROXY` контейнера `pi-agent` — их трафик идёт через squid так же, как у самого агента, без отдельной настройки. `searxng` сам также ходит через squid (см. `outgoing.proxies` в `settings.yml`).

Приоритет источников (официальная документация выше community-контента) — правило в `shared/conventions/common.md`, не техническое ограничение.

## Сетевой доступ: ограниченный или полный

### Защищённый режим (`make run`) — по умолчанию

`harness-net` — `internal: true`, нет маршрута в интернет. Выход только через `egress-proxy` с allowlist. Гарантия сетевого уровня — не обходится сменой инструмента внутри агента.

### Открытый режим (`make run-open`)

Для разовых задач с непредсказуемыми источниками. `pi-agent` дополнительно подключается к `egress-net`, прокси-переменные сбрасываются — трафик идёт напрямую, allowlist и защита от exfiltration отключены полностью. Использовать осознанно.

`docker-compose.open-network.yml` **не трогает** саму сеть `harness-net` (это вызвало бы конфликт пересоздания, если инфраструктура уже поднята) — только добавляет `pi-agent` в `egress-net`.

### Расширение allowlist

```bash
make denied                                              # что заблокировано
# добавить домен в proxy/allowlist-base.txt (с комментарием: дата, причина)
docker compose exec egress-proxy squid -k reconfigure    # применить без пересборки
```

Один общий файл allowlist (без разделения база/проект) — харнесс переиспользуется между похожими проектами, домены пересекаются.

## КРИТИЧЕСКИ ВАЖНО: pi-agent-home volume перекрывает пакеты образа

`pi install` кладёт пакеты в `/root/.pi/agent` — тот же путь, что смонтирован как persistent volume. Если volume уже существует, Docker не обновляет его новым содержимым образа при пересборке. После ЛЮБОГО изменения Dockerfile, затрагивающего `pi install`:

```bash
make clean
docker compose build pi-agent
```

То же правило — для сброса залипшей дефолтной модели.

## Java — multi-stage сборка

`openjdk-21-jdk` нет ни в bookworm, ни в backports (появился только в trixie). Dockerfile берёт готовый JDK 21 из `eclipse-temurin` отдельным build-stage, копирует поверх node-образа. Версия JDK — часть конкретного `agents/pi/Dockerfile`, не универсальный параметр харнесса.

## models.json

- `local-llama` — модель указывается явно (у llama.cpp нет своего каталога).
- `openrouter` — модели не перечисляются, провайдер получает список динамически по API-ключу.
- pi запоминает последний выбор модели в volume между запусками — порядок в файле не определяет дефолт после первого запуска.

## Диагностика

Точка входа — `entrypoint.sh`, для обычных shell-команд переопределять entrypoint:
```bash
docker compose run --rm --entrypoint bash pi-agent -c "команда"
```

```bash
# MCP БД напрямую
docker compose run --rm --entrypoint bash pi-agent -c \
  "curl -sv http://mcp-db:8080/mcp 2>&1 | head -30"

# БД в обход MCP
docker compose run --rm --entrypoint bash pi-agent -c \
  "PGPASSWORD=\$DB_AGENT_PASSWORD psql -h host.docker.internal -p \$DB_PORT -U \$DB_AGENT_USER -d \$DB_NAME -c 'SELECT current_user;'"

# Сеть — разрешённый и заблокированный домен
docker compose run --rm --entrypoint bash pi-agent -c \
  "curl -sv --max-time 10 https://openrouter.ai 2>&1 | tail -20"
docker compose run --rm --entrypoint bash pi-agent -c \
  "curl -sv --max-time 10 https://example.com 2>&1 | tail -20"

# search/fetch MCP вручную (должны зависнуть в ожидании STDIN — это нормально)
docker compose run --rm --entrypoint bash pi-agent -c \
  "HOME=/tmp SEARXNG_URL=http://searxng:8080 mcp-searxng"
docker compose run --rm --entrypoint bash pi-agent -c \
  "HOME=/tmp fetch-mcp"

# SearXNG напрямую
docker compose run --rm --entrypoint bash pi-agent -c \
  "curl -s 'http://searxng:8080/search?q=test&format=json' | head -c 300"
```

## Частые ошибки

| Ошибка | Причина / решение |
|---|---|
| `required variable PROJECT_PATH is missing a value` | `export PROJECT_PATH=...` не выполнен в текущем терминале |
| YAML `could not find expected ':'` при include | Отступы — сервис должен быть на 2 пробела внутри `services:` |
| `fatal: detected dubious ownership in repository` | Образ собран до `git config --global --add safe.directory /workspace` — пересобрать |
| `Unable to locate package openjdk-21-jdk` | Пакета нет в bookworm/backports — решено multi-stage с eclipse-temurin |
| DBHub: `readonly field... must be per-tool` | `readonly` должен быть в `[[tools]]`, не `[[sources]]` |
| DBHub: `Host 'mcp-db' is not allowed` (403) | Нужен `--allowed-hosts mcp-db,localhost,127.0.0.1` |
| mcp-db: `ENETUNREACH` | `mcp-db` не подключён к `egress-net` — нет маршрута до `host.docker.internal` |
| mcp-db: `ECONNREFUSED` | Маршрут есть, но Postgres на хосте не слушает нужный адрес/порт (`ss -tlnp \| grep 5432`) |
| egress-proxy: `Cannot open access.log... Permission denied` | Bind-mount для логов не подходит — использовать named volume, не bind-mount |
| `make run-open`: `network harness-net has active endpoints` | Override не должен снимать `internal: true` с сети — только добавлять `pi-agent` в `egress-net` |
| SearXNG: `server.secret_key is not changed` (бесконечный рестарт) | Задать реальный `SEARXNG_SECRET` в `.env` (генерировать `openssl rand -hex 32`) |
| SearXNG: `Temporary failure in name resolution` для отдельных движков | `use_default_settings` подключает все дефолтные движки, включая незапрошенные (wikidata, radio_browser и т.д.) — использовать `use_default_settings.engines.keep_only` вместо полного дефолтного списка |
| SearXNG не резолвит DNS вообще | Внутренний HTTP-клиент SearXNG не читает `HTTP_PROXY` из окружения — прокси задаётся отдельно, через `outgoing.proxies` в `settings.yml` |
| MCP `search`/`fetch`: `npm error EROFS`, `read-only file system` | `npx` не находит пакет локально и пытается скачать — писать некуда (read-only контейнер). Вызывать установленный бинарник напрямую (`command: "fetch-mcp"`), не через `npx` |
| Свежеустановленный pi-пакет не виден | Снести `pi-agent-home` volume (`make clean`) — см. раздел про volume выше |

## Известные несовершенства (стоит поправить)

- `docker-compose.yml`: `maven-cache:/root/.m` — опечатка, должно быть `/root/.m2` (правильный путь кэша Maven), иначе кэширование зависимостей не работает.
- `model/llama-cpp.yml`: сервис подключён и к `harness-net`, и к `egress-net` — модель полностью локальная, реального интернета не требует. Сейчас это единственный сервис с прямым выходом в сеть в обход squid даже в защищённом режиме. Рекомендуется оставить только `harness-net`.

## Текущий статус

Реализовано и проверено практически:
- Файловая/сетевая/git-изоляция, эфемерный контейнер, AGENTS.md не коммитится
- БД: readonly-роль + readonly MCP-tool, доступ через `host.docker.internal`, чтение подтверждено, запись заблокирована
- MCP: `mcp-db` (DBHub), `search` (SearXNG + mcp-searxng), `fetch` (fetch-mcp) — все три работают
- Сеть: squid allowlist, защищённый и открытый режимы оба проверены — allowlist пропускает разрешённые домены, блокирует остальные (403), internal-сеть держит границу даже без прокси-переменных
- Makefile — единая точка входа, без ручного `chmod` после `git clone`
- Оба провайдера модели (local-llama, openrouter) работают и переключаемы

## Решения и их причины

- Один `.env` в корне харнесса — минимум мест для секретов, проще переносить харнесс как одну папку.
- Один `mcp-db` для всех агентов, не свой на каждого — единая точка правды, единые креды, единая политика доступа.
- DBHub вместо Postgres MCP Pro — token-efficient (2 тула вместо десятков), readonly на уровне движка.
- `mcp.json` монтируется в global-путь агента, не в `/workspace` — project-level MCP-конфиг untrusted по умолчанию.
- git push/pull исключены инфраструктурно — единственная точка ручного контроля перед выходом изменений наружу.
- Сетевой allowlist на уровне сети (internal + squid), а не только на уровне инструмента — allowlist внутри отдельного MCP-инструмента тривиально обходится через bash/curl, которые у агента уже есть. Реальная граница должна быть там, где её нельзя обойти сменой инструмента.
- Открытый режим — через отдельный override-файл, не переменную в `.env` — защищённый режим гарантированно остаётся дефолтом, не зависит от того, забыли ли выставить флаг.
- `search`/`fetch` MCP — open-source стек без API-ключей (SearXNG вместо Brave/Tavily), работают как stdio-процессы внутри `pi-agent`, а не отдельные HTTP-сервисы — меньше контейнеров, автоматическое наследование сетевых ограничений агента без ручной синхронизации override-файлов.
- Логи squid — в named volume, не bind-mount — bind-mount ломается из-за несовпадения владельца директории между хостом и пользователем `proxy` внутри контейнера squid.