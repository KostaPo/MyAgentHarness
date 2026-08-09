# MyAgentHarness

Изолированная инфраструктура для запуска AI coding-агентов (pi, далее —
Claude Code) поверх любого локального проекта. Локальная LLM (llama.cpp)
+ фолбэк на OpenRouter, общий MCP-сервер для доступа к БД.

## Структура
```text
MyAgentHarness/
├── README.md
├── .env
├── .env.example
├── .gitignore
├── docker-compose.yml
├── model/
│   └── llama-cpp.yml
├── mcp/
│   └── dbhub.toml
├── agents/
│   ├── pi/
│   │ ├── Dockerfile
│   │ ├── entrypoint.sh
│   │ ├── models.json
│   │ └── mcp.json
│   └── claude-code/ (заготовка на будущее)
└── shared/
    └── conventions/
        └── common.md
```    

- model/llama-cpp.yml   — сервис локальной модели (GPU, OpenAI-совместимый API)
- mcp/                   — общая MCP-инфраструктура (сейчас: DBHub для БД)
- agents/pi/             — Dockerfile + entrypoint.sh + models.json + mcp.json для pi
- agents/claude-code/    — заготовка под второго агента (аналогичный паттерн)
- shared/conventions/    — общие правила поведения, монтируются как AGENTS.md/CLAUDE.md

## Схема взаимодействия

```text
                              ┌──────────────────────┐
                              │      LLM PROVIDER    │
                              └──────────┬───────────┘
                                         │
                         ┌───────────────┴───────────────┐
                         │                               │
                         ▼                               ▼
                ┌─────────────────┐             ┌─────────────────┐
                │    llama-cpp    │             │   OpenRouter    │
                │   Local / GPU   │             │   Cloud / API   │
                │     :1234       │             │  100s of models │
                └────────┬────────┘             └────────┬────────┘
                         │                               │
                         └───────────────┬───────────────┘
                                         │
                                         │ LLM
                                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│                         AGENT HARNESS                                │
│                                                                      │
│                     ┌────────────────────┐                           │
│                     │     pi-agent       │                           │
│                     │                    │                           │
│                     │   Agent runtime    │                           │
│                     │                    │                           │
│                     │  read_only: true   │                           │
│                     │  ephemeral (--rm)  │                           │
│                     │  no SSH keys       │                           │
│                     └─────────┬──────────┘                           │
│                               │                                      │
│                    ┌──────────┴──────────┐                           │
│                    │                     │                           │
│                    ▼                     ▼                           │
│          ┌──────────────────┐   ┌──────────────────┐                 │
│          │    CODE TOOLS    │   │      MCP-DB      │                 │
│          │                  │   │      DBHub       │                 │
│          │  filesystem      │   │    read-only     │                 │
│          │  git             │   │                  │                 │
│          │  shell           │   └────────┬─────────┘                 │
│          │  tests           │            │                           │
│          └────────┬─────────┘            │                           │
│                   │                      │                           │
└───────────────────┼──────────────────────┼───────────────────────────┘
                    │                      │
                    ▼                      ▼
       ╔══════════════════════╗   ╔══════════════════════╗
       ║  PROJECT CODEBASE    ║   ║     PROJECT DB       ║
       ║                      ║   ║                      ║
       ║                      ║   ║     PostgreSQL       ║
       ║  /home/kostapo/...   ║   ║       :5432          ║
       ║                      ║   ║                      ║
       ║  mounted as          ║   ║     read-only        ║
       ║  /workspace          ║   ║       access         ║
       ╚══════════════════════╝   ╚══════════════════════╝
```
### Ключевые изоляционные границы

- **Доступ агента к файловой системе ограничен проектом:** единственный volume mount в `pi-agent` — `${PROJECT_PATH}` → `/workspace`; остальная файловая система хоста агенту не видна.
- **`pi-agent` эфемерен:** контейнер запускается с `--rm` и `read_only: true`, поэтому агент не может сохранять изменения во внутренней файловой системе контейнера между запусками.
- **Git credentials не предоставляются:** SSH-ключи, credential helpers и другие учётные данные хоста не монтируются в контейнер. Доступ к приватным Git remotes из агента невозможен без явно предоставленных credentials.
- **Доступ к БД ограничен на двух уровнях:** PostgreSQL использует отдельную `readonly`-роль, а `mcp-db` дополнительно работает в режиме `readonly`, заданном в MCP-конфигурации.
- **`mcp-db` — единая точка доступа к PostgreSQL:** все агенты harness получают доступ к БД через один контролируемый MCP-слой, что позволяет централизованно применять политики доступа и ограничения.

> **Важно:** `read_only: true` у Docker-контейнера ограничивает файловую систему самого контейнера и **не означает read-only доступ к PostgreSQL**.
>
> Доступ к БД ограничивается отдельно через PostgreSQL `readonly` role и `mcp-db` в режиме `readonly`.

## Секреты — единый .env в корне

Все секреты (OPENROUTER_API_KEY, креды readonly-юзера БД) лежат в
одном .env в корне харнеса. Файл в .gitignore, НИКОГДА не коммитится.
.env.example — шаблон с именами переменных без значений, коммитится.

Все агенты и mcp-db подключают ОДИН И ТОТ ЖЕ .env через env_file —
секрет меняется в одном месте, виден всем сразу.

Это открытый текст на диске (не зашифровано) — осознанный выбор для
соло-разработки на одной доверенной машине. Для команды/чужой машины —
заменить на Vault/SOPS.

ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ: DB_* переменные привязаны к ОДНОМУ активному проекту.
При переключении на другой проект с БД — обновить DB_* в .env вручную.

## Быстрый старт

Первый раз (один раз при клонировании):

    cp .env.example .env
    nano .env   # заполнить OPENROUTER_API_KEY, DB_* значениями

Каждый рабочий запуск:

    export PROJECT_PATH=/абсолютный/путь/до/проекта
    docker compose up -d llama-cpp mcp-db
    docker compose run --rm pi-agent

Внутри сессии pi (если нужна БД):

    /mcp connect postgres

Проверка, что модель отвечает (по желанию):

    curl http://localhost:1234/v1/models

Остановить всё:

    docker compose down

## Требование к проекту — readonly-юзер должен существовать в БД заранее

Харнес НЕ создаёт этого юзера сам — это ответственность проекта (БД
принадлежит проекту, а не харнесу). Прежде чем подключать харнес к БД,
в init-скрипты проектного docker-compose (docker-entrypoint-initdb.d)
должен быть добавлен скрипт создания readonly-роли.

Референсный скрипт (использовать как шаблон, имя/пароль роли задать через
переменные окружения проектного compose, не хардкодить в открытом виде
в реальном проекте):

    DO $$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'llm_agent') THEN
                CREATE ROLE llm_agent
                    LOGIN
                    PASSWORD 'llm_agent_password'
                    NOCREATEDB
                    NOCREATEROLE
                    NOSUPERUSER
                    NOBYPASSRLS
                    CONNECTION LIMIT 5;
            END IF;
        END
    $$;

    GRANT pg_read_all_data TO llm_agent;

    REVOKE ALL ON SCHEMA public FROM llm_agent;

После создания роли — прописать её креды (имя, пароль) в .env харнеса
(DB_AGENT_USER, DB_AGENT_PASSWORD), а также убедиться, что порт БД
опубликован на хост (ports: "5432:5432" в проектном compose) — это
нужно для доступа через host.docker.internal.

## MCP-сервер для БД (DBHub)

Единый MCP-сервер (mcp-db, образ bytebase/dbhub), общий для всех
агентов харнеса. Подключается к БД через те же DB_AGENT_* переменные,
что и прямой psql-доступ — тот же readonly-пользователь, никаких
отдельных кредов.

Конфигурация — mcp/dbhub.toml:

    [[sources]]
    id = "default"
    description = "Project database (read-only)"
    dsn = "${DSN}"

    [[tools]]
    name = "execute_sql"
    source = "default"
    readonly = true

DSN собирается в docker-compose.yml из DB_AGENT_* и передаётся как
переменная окружения контейнера mcp-db, где ${DSN} интерполируется
самим DBHub при чтении toml.

ВАЖНЫЕ НЮАНСЫ, НАЙДЕННЫЕ НА ПРАКТИКЕ:
- readonly задаётся на уровне [[tools]], НЕ на уровне [[sources]] —
  DBHub явно отклоняет source-level readonly с ошибкой
- MCP-эндпоинт сервера — /mcp, НЕ корень /
- DBHub по умолчанию принимает запросы ТОЛЬКО с loopback-адресов
  (защита от DNS rebinding) — обращение по docker-сервисному имени
  (mcp-db) требует явного --allowed-hosts mcp-db,localhost,127.0.0.1
- HTTP-транспорт DBHub не аутентифицирует клиентов — это не проблема
  внутри изолированной harness-net (сервер не публикует порт наружу),
  но не годится, если сеть станет менее закрытой

## Подключение MCP в pi (pi-mcp)

pi НЕ включает MCP в ядро — это осознанное архитектурное решение
разработчиков. MCP подключается через сторонний пакет @spences10/pi-mcp:

    RUN pi install npm:@spences10/pi-mcp

Пакет читает конфиг mcp.json (или .mcp.json — формат совместимый с
Claude Code). У нас — agents/pi/mcp.json, монтируется в
/root/.pi/agent/mcp.json (global location), а НЕ в /workspace — так
конфиг харнеса не требует ручного подтверждения доверия при каждом
запуске (project-level mcp.json считается untrusted по умолчанию).

agents/pi/mcp.json:

    {
      "mcpServers": {
        "postgres": {
          "url": "http://mcp-db:8080/mcp"
        }
      }
    }

ВАЖНО: MCP-серверы НЕ подключаются автоматически при старте сессии —
нужно явно выполнить /mcp connect postgres. Инструмент появляется
в pi как mcp__postgres__execute_sql.

## КРИТИЧЕСКИ ВАЖНО: pi-agent-home volume перекрывает пакеты образа

pi install кладёт пакеты в /root/.pi/agent — тот же путь, что смонтирован
как persistent volume (pi-agent-home). Если volume уже существует и
непустой, Docker НЕ обновляет его новым содержимым образа при
пересборке — свежеустановленные через RUN pi install пакеты (и любые
другие изменения по этому пути) будут невидимы в рантайме контейнера,
пока volume не будет удалён и не создастся заново с чистого листа.

После ЛЮБОГО изменения Dockerfile, затрагивающего pi install, —
обязательно:

    docker compose down
    docker volume rm myagentharness_pi-agent-home
    docker compose build pi-agent

То же самое правило касается сброса залипшей дефолтной модели.

## Изоляция агента (модель угроз)

Жёсткая граница (техническая, не обходится):
- Агент видит ТОЛЬКО /workspace (примонтированный путь к проекту)
- read_only: true — сам контейнер неизменяем в рантайме, /tmp — tmpfs
- Нет git credentials — push/pull физически невозможны
- Контейнер эфемерен (--rm): при выходе удаляется целиком
- БД доступна строго read-only — на уровне СУБД (readonly-роль) И
  дополнительно на уровне MCP-сервера (readonly tool), двойная защита

Мягкая граница (уровень промпта, не гарантирована техническими средствами):
- shared/conventions/common.md — поведенческие правила, соблюдение
  зависит от модели

ВАЖНЫЙ ПРИНЦИП, ПОДТВЕРЖДЁННЫЙ НА ПРАКТИКЕ: обе границы должны работать
вместе, ни одна не заменяет другую. Пример: агент при работе с БД
самостоятельно нашёл в application.yml проекта credentials самого
приложения (не readonly) и попытался ими воспользоваться. Попытка
провалилась только потому, что localhost внутри контейнера физически
не указывает на БД (сетевая изоляция спасла). Исправлено явным правилом
в конвенциях. Полагаться только на текстовые правила недостаточно,
только на техническую изоляцию — тоже недостаточно.

Доступ к БД проекта — через host.docker.internal (порт БД опубликован
на хост через ports: в проектном compose). Используется и для прямого
psql-доступа, и для DSN самого MCP-сервера.

## AGENTS.md — не попадает ни в реальный проект, ни в git

shared/conventions/common.md монтируется ПОВЕРХ пути /workspace/AGENTS.md
как отдельный bind-mount — подмена, видимая только внутри контейнера.
На хосте файла AGENTS.md физически не существует.

Папка .git — часть реального проекта, примонтирована как есть. Значит
git add AGENTS.md реально записал бы коммит в историю на диске.
Исправлено технически: entrypoint.sh при каждом старте добавляет
AGENTS.md в .git/info/exclude. Работает ТОЛЬКО при запуске через
настоящий entrypoint (pi) — диагностика через --entrypoint bash идёт
в обход, это нормально.

## Java — почему multi-stage сборка образа

openjdk-21-jdk отсутствует и в bookworm, и в bookworm-backports
(появился только в Debian 13/trixie). Dockerfile берёт готовый JDK 21
из eclipse-temurin как отдельный build-stage и копирует только сам JDK
поверх node-образа.

ВАЖНО: версия JDK — НЕ универсальный параметр харнеса, а часть
agents/pi/Dockerfile под конкретный класс проектов. Другой проект с
другой версией Java или другим языком потребует правки Dockerfile или
отдельного варианта образа.

## models.json — минимальная конфигурация

local-llama: модель указывается ЯВНО — единственный способ, которым pi
о ней узнаёт (у llama.cpp сервера нет своего динамического каталога).

openrouter: models НЕ указываются — провайдер регистрируется только
через baseUrl + apiKey, список моделей pi получает динамически из
живого API OpenRouter (сотни моделей).

ВАЖНО ПРО ДЕФОЛТНУЮ МОДЕЛЬ: pi сохраняет последний выбор в volume
pi-agent-home между запусками, порядок в models.json НЕ определяет
дефолт после первого запуска. Сброс — см. раздел про volume выше.

## Диагностика внутри контейнера (не сама TUI-сессия)

Точка входа — entrypoint.sh (сам запускает pi). Для обычных shell-команд
переопределяй entrypoint:

    docker compose run --rm --entrypoint bash pi-agent -c "команда"

Без этого команда интерпретируется как аргумент самому pi, а не как
shell-команда — ошибка вида "Cannot convert argument to a ByteString...".

Диагностика MCP-сервера напрямую:

    docker compose run --rm --entrypoint bash pi-agent -c \
      "curl -sv http://mcp-db:8080/mcp 2>&1 | head -30"

Диагностика БД напрямую (в обход MCP):

    docker compose run --rm --entrypoint bash pi-agent -c \
      "PGPASSWORD=\$DB_AGENT_PASSWORD psql -h host.docker.internal -p \$DB_PORT -U \$DB_AGENT_USER -d \$DB_NAME -c 'SELECT current_user;'"

## Частые ошибки и их причины

**"required variable PROJECT_PATH is missing a value"**
PROJECT_PATH не задан в текущей сессии терминала.

**YAML "could not find expected ':'" / паника Compose при include**
Проверить отступы — сервис должен быть вложен под services: с отступом
в 2 пробела, а не стоять с ним на одном уровне.

**"fatal: detected dubious ownership in repository at '/workspace'"**
Исправлено в Dockerfile через git config --global --add safe.directory
/workspace. Если ошибка вернулась — образ собран до этой правки,
пересобрать.

**"Unable to locate package openjdk-21-jdk"**
Пакета нет ни в bookworm, ни в backports. Решено через multi-stage с
eclipse-temurin.

**MCP-сервер БД: "readonly field... must be configured per-tool"**
readonly в toml-конфиге DBHub должен быть в [[tools]], не в [[sources]].

**MCP-сервер БД: "Host 'mcp-db' is not allowed" (403)**
Нужен явный флаг --allowed-hosts mcp-db,localhost,127.0.0.1.

**Свежеустановленный pi-пакет не виден в контейнере**
См. раздел "КРИТИЧЕСКИ ВАЖНО" выше — снести pi-agent-home volume.

**Агент использует credentials приложения вместо DB_AGENT_***
Исправлено правилом в shared/conventions/common.md.

## Текущий статус (для восстановления контекста в новой сессии)

Полностью реализовано и проверено практически:
- Инфраструктура: harness-net, llama-cpp, pi-agent (multi-stage Java 21),
  файловая изоляция, git локально работает и не коммитит AGENTS.md,
  push технически невозможен
- БД: readonly-роль llm_agent (создаётся на стороне проекта), доступ
  через host.docker.internal, подтверждены и чтение, и блокировка записи
- MCP: единый сервер mcp-db (DBHub) для доступа к БД, readonly на
  уровне tool-конфига, pi подключается через сторонний пакет
  @spences10/pi-mcp, инструмент mcp__postgres__execute_sql работает
- Секреты (.env) реально доходят до всех сервисов (agent, mcp-db)
- Оба провайдера модели (local-llama, openrouter) работают и переключаемы
- Правило про DB_AGENT_* и MCP как основной способ доступа зафиксировано
  в общих конвенциях

## Решения и их причины

- .env в корне харнеса, не вне проекта: минимум мест для хранения
  секретов, проще бэкапить/переносить весь харнес как одну папку
- PROJECT_PATH передаётся при запуске через переменную окружения:
  харнес одинаково работает с любым проектом
- mcp/ — отдельная папка вне agents/: MCP-сервер общий для всех
  агентов, не принадлежит конкретному
- Один MCP-сервер (mcp-db) для всех агентов, а не свой на каждого:
  единая точка правды для доступа к БД, единые креды, единая точка
  изменения политики доступа
- DBHub выбран вместо Postgres MCP Pro: официально рекомендован для
  Claude Code, token-efficient (2 тула вместо десятков), read-only на
  уровне движка, multi-database на будущее
- mcp.json харнеса монтируется в global-путь агента, а не в /workspace:
  project-level MCP-конфиг untrusted по умолчанию
- git push/pull исключены инфраструктурно: единственная точка ручного
  контроля перед выходом изменений наружу
- AGENTS.md исключается из git через .git/info/exclude в entrypoint.sh:
  техническая гарантия вместо надежды на соблюдение текстового правила
- Readonly-роль в БД создаётся на стороне проекта, не харнесом
- Контейнер агента эфемерен (--rm): чистое состояние при каждом запуске
- Правило про DB_AGENT_* и приоритет MCP вынесено в общие конвенции,
  а не патч под pi: обнаружено практически — агент пытался использовать
  credentials приложения из application.yml