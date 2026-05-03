# Два репозитория: публичный Planulix и коммерческий слой

Публичный репозиторий: **[github.com/pyatkovpetr/Planulix](https://github.com/pyatkovpetr/Planulix)**. В интерфейсе продукт отображается как **Planulix**; репозиторий и юридическое имя — **Planulix**.

Сейчас это **десктопный и мобильный** клиент на Flutter для **сессий Kimi Code и Claude Code** (плюс другие coding-CLI), в паре с **self-hosted** Go-gateway на VPS/локальной машине.

Цель структуры ниже: **публичный** монорепо (клиент + gateway), отдельный **закрытый** репозиторий под хостинг, биллинг и мульти-тенант.

## Репозиторий 1 — `Planulix` (публичный)

| Поле | Значение |
|------|----------|
| **Лицензия** | **Apache-2.0** — патентная оговорка, привычна для корпоративных форков; альтернатива **MIT**, если нужен минимум юридического текста. |
| **Назначение** | Flutter **desktop + mobile** (клиент для сессий Kimi/Claude и др.) + минимальный Go **gateway** (сессии, агенты, health, токен/API key). |
| **Релизы** | Теги `mobile/v*`, `gateway/v*` или общие `v*` с changelog по компонентам. |

### Предлагаемая структура (после выноса из монорепо)

```text
Planulix/
├── LICENSE                    # Apache-2.0
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
├── docs/
│   ├── self-host.md           # установка gateway на VPS (systemd, TLS, firewall)
│   └── api.md                 # контракт REST/WebSocket между mobile и gateway
│
├── mobile/                    # Flutter-приложение
│   ├── pubspec.yaml
│   ├── lib/
│   ├── android/
│   ├── ios/
│   ├── macos/
│   └── test/
│
└── gateway/                   # Go self-hosted ядро (сейчас каталог server/)
    ├── go.mod
    ├── cmd/
    │   └── gateway/
    │       └── main.go
    ├── internal/
    │   ├── api/
    │   ├── session/
    │   ├── agent/
    │   ├── auth/
    │   └── config/
    ├── deployments/
    │   ├── systemd/
    │   ├── docker/
    │   └── scripts/
    │       └── install.sh
    └── README.md
```

### Что остаётся только здесь (open)

- Код мобильного клиента и **open** API клиента (Dart).
- Gateway: приём сообщений, прокси к локальным CLI, файловые проекты на VPS, capabilities discovery.
- Скрипты установки и примеры **без** привязки к твоему SaaS.

### Что из текущего `server/` сюда не переносится

Переносится в репозиторий 2 или вырезается из open через `build tags` / отдельный модуль:

- GitHub OAuth как облачный вход, привязка к твоему продукту.
- `cloud_gateway_agent.go`, исходящий WebSocket-воркер к внешнему gateway при `PLANULIX_CLOUD_*` (опционально).
- Интеграции с внешними «провайдерскими» фичами, если считаешь их коммерческим отличием.
- Любой код, который ходит в **твой** control plane.

При желании оставить один бинарь в open: используйте **build tag** `//go:build !enterprise` для open и репозиторий 2 как replace-модуль с `//go:build enterprise`.

---

## Репозиторий 2 — `planulix-cloud` (закрытый / source-available)

| Поле | Значение |
|------|----------|
| **Лицензия** | **Proprietary** (свой `LICENSE`). Альтернатива — **BUSL**-подобная с конверсией в Apache через N лет. |
| **Назначение** | Hosted control plane: аккаунты, команды, биллинг, install-токены, опционально relay, дашборд, push-инфраструктура. |

### Предлагаемая структура

```text
planulix-cloud/
├── LICENSE
├── README.md
│
├── control-plane/
│   ├── go.mod
│   ├── cmd/
│   │   └── control-plane/
│   └── internal/
│       ├── billing/
│       ├── org/
│       ├── tokens/
│       └── integrations/
│
├── relay/                     # опционально
├── web/                       # опционально
└── contracts/
    └── gateway-admin-v1.yaml
```

### Связь с репозиторием 1

- Мобильное приложение в **store** может собираться с **flavor**: `foss` (только публичный gateway) и `store` (модуль, ссылающийся на `planulix-cloud` API).
- Gateway на VPS пользователя — **только из репозитория Planulix**; репозиторий 2 лишь **регистрирует** ноду и выдаёт секреты при платном режиме.

---

## Контракт между репозиториями

1. **Версионируемый API** в `Planulix/docs/api.md` + при необходимости OpenAPI в `Planulix/gateway/api/openapi.yaml`.
2. Репозиторий 2 **не форкает** мобильный UI целиком; добавляет endpoints и ключи в конфиг клиента.
3. Секреты провайдеров LLM по умолчанию **только на VPS** (gateway из репозитория 1).

---

## Миграция с текущего дерева

| Сейчас | Репозиторий 1 `Planulix` |
|--------|-------------------------|
| `lib/`, `android/`, … | `mobile/` (или корень mono-repo как сейчас) |
| `server/*.go` (ядро) | `gateway/internal/...` |

| Сейчас | Репозиторий 2 |
|--------|----------------|
| OAuth/облако/saas в `server/` | `control-plane/...` |

Удалите из git артефакты сборки (`server/planulix*`, бинарники) — в `.gitignore` уже есть маски.

---

## Лицензии

- **Apache-2.0** для публичного `Planulix` — если цель форки компаниями.
- **MIT** — если нужна максимальная простота.
- `planulix-cloud` — только **явный proprietary**; не смешивайте в одном каталоге с Apache без чёткого разделения.
