# Telegram-гайды для канала Planulix

Ниже 6 готовых постов для Telegram-канала/сообщества. Их можно публиковать серией после GitHub-релиза.

## Пост 1. Что такое Planulix и зачем он нужен

**Заголовок:** Planulix: один пульт для Claude Code, Kimi, Codex и других CLI-агентов

Если вы пользуетесь AI-кодерами через CLI, сначала всё выглядит просто:

```bash
cd project
claude
```

или:

```bash
cd project
codex
```

Но когда проектов становится 5-10, начинается хаос:

- где запущена нужная сессия;
- какой агент работал в каком проекте;
- что уже было исправлено;
- сколько токенов ушло;
- почему на VPS всё работает, а с ноутбука не видно;
- как продолжить задачу с телефона.

Planulix решает эту задачу как self-hosted диспетчер сессий.

Что внутри:

- Go Gateway на вашем VPS/сервере;
- macOS/Android клиент;
- список сессий по агентам и проектам;
- чат с агентом;
- файловый проводник проекта;
- диагностика подключения;
- примерная аналитика расходов.

Скачать релиз:
https://github.com/pyatkovpetr/Planulix/releases/tag/v1.0.0

Репозиторий:
https://github.com/pyatkovpetr/Planulix

**Идея простая:** AI-агенты работают там, где лежит проект, а вы управляете ими из одного интерфейса.

---

## Пост 2. Быстрый старт: ставим Planulix Gateway на VPS

**Заголовок:** Как поставить Planulix Gateway на VPS за пару минут

Planulix состоит из клиента и gateway.

Gateway — это Go-сервер, который запускает CLI-агентов и отдаёт API для клиента.

Минимальная установка на Linux VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/pyatkovpetr/Planulix/main/scripts/install_gateway_remote.sh \
  | AUTH_TOKEN='your-secret-token' bash -
```

Что делает скрипт:

- скачивает готовый gateway из GitHub Releases;
- создаёт директорию `~/.planulix-gateway`;
- ставит бинарь `planulix-gateway`;
- поднимает systemd-сервис;
- запускает API на порту `8990`.

Потом в клиенте указываем:

```text
Server URL: http://<your-vps-ip>:8990/api
Auth Token: your-secret-token
```

Если не хотите открывать порт наружу, используйте Tailscale:

```text
Server URL: http://100.x.x.x:8990/api
```

Проверить gateway:

```bash
curl http://127.0.0.1:8990/healthz
```

Перезапуск:

```bash
sudo systemctl restart planulix-gateway
```

Логи:

```bash
journalctl -u planulix-gateway -f
```

Релиз:
https://github.com/pyatkovpetr/Planulix/releases/tag/v1.0.0

---

## Пост 3. Как подключить macOS и Android клиент к своему Gateway

**Заголовок:** Подключаем Planulix-клиент к своему серверу

После установки gateway надо подключить клиент.

В релизе есть:

- `Planulix-macOS-v1.0.0.zip`;
- `Planulix-Android-v1.0.0.apk`.

Скачать:
https://github.com/pyatkovpetr/Planulix/releases/tag/v1.0.0

### macOS

1. Скачайте `Planulix-macOS-v1.0.0.zip`.
2. Распакуйте.
3. Откройте `Planulix.app`.
4. Если macOS ругается на приложение из интернета: правый клик → **Open**.

### Android

1. Скачайте `Planulix-Android-v1.0.0.apk`.
2. Откройте APK на телефоне.
3. Разрешите установку из браузера/файлового менеджера.

### Настройка подключения

В приложении укажите:

```text
Server URL: http://<host>:8990/api
Auth Token: тот же AUTH_TOKEN, что на gateway
```

Рекомендация: если это VPS без HTTPS, лучше подключаться через Tailscale:

```text
http://100.x.x.x:8990/api
```

После сохранения откройте Settings → diagnostics и проверьте:

- API доступен;
- токен подходит;
- gateway видит сетевые интерфейсы;
- CLI-агенты установлены.

---

## Пост 4. Как работать с несколькими проектами

**Заголовок:** Один экран для багфиксов, DevOps и AI-сессий по всем проектам

Типичный сценарий:

- в одном проекте надо поправить Android-сборку;
- во втором обновить gateway;
- в третьем разобраться с Docker;
- в четвёртом проверить баг после релиза.

Если делать это в терминалах, легко потерять контекст.

В Planulix можно:

1. Выбрать агент: Claude / Kimi / Codex / Cursor.
2. Отфильтровать сессии по проекту.
3. Открыть нужную сессию.
4. Посмотреть историю.
5. Продолжить чат или создать новую задачу.
6. Открыть файл проекта в встроенном проводнике.

Полезный workflow:

```text
Sessions -> Agent: Codex -> Project: smart-budget -> open session
```

или:

```text
Explorer -> /root/projects/my-app -> chat -> "найди причину падения CI"
```

Planulix не заменяет IDE. Он закрывает другой слой: управление агентами и сессиями там, где проекты реально лежат.

Если проект на VPS, агент тоже работает на VPS. Клиент только отправляет команды и показывает результат.

---

## Пост 5. Codex в Planulix: ChatGPT OAuth vs OpenAI API key

**Заголовок:** Почему у Codex есть "Codex default" и "GPT-5.2 Codex"

В Codex CLI есть важная особенность: вход через ChatGPT и OpenAI Platform API key — это не одно и то же.

Есть два режима:

### 1. ChatGPT / OAuth

Вы логинитесь:

```bash
codex login
```

CLI использует ваш ChatGPT-аккаунт и свои доступные модели/лимиты.

В Planulix для этого режима выбирайте:

```text
Codex default
```

Это значит: не передавать `--model`, пусть CLI сам выберет корректную модель.

### 2. OpenAI API key

Вы передаёте:

```text
OPENAI_API_KEY
```

Это уже Platform API с отдельным биллингом и лимитами.

Для этого режима можно использовать API-модели, например:

```text
GPT-5.2 Codex
```

Почему это важно?

Если передать `--model gpt-5.2-codex` в ChatGPT/OAuth режиме, Codex CLI может вернуть ошибку:

```text
'gpt-5.2-codex' model is not supported when using Codex with a ChatGPT account
```

Поэтому безопасный выбор по умолчанию — `Codex default`.

---

## Пост 6. Что смотреть, если Planulix не подключается

**Заголовок:** Мини-чеклист диагностики Planulix

Если клиент не видит gateway или агенты не отвечают, проверьте по шагам.

### 1. Gateway жив?

На сервере:

```bash
curl http://127.0.0.1:8990/healthz
```

Если systemd:

```bash
sudo systemctl status planulix-gateway
journalctl -u planulix-gateway -f
```

### 2. URL правильный?

В клиенте нужен URL с `/api`:

```text
http://<host>:8990/api
```

Не просто:

```text
http://<host>:8990
```

### 3. Токен совпадает?

`AUTH_TOKEN` на gateway должен совпадать с Auth Token в клиенте.

### 4. Сеть доступна?

Если используете Tailscale, проверьте, что оба устройства в одной tailnet.

Пример URL:

```text
http://100.x.x.x:8990/api
```

### 5. CLI установлен на gateway?

Planulix управляет агентами на той машине, где запущен gateway.

То есть если gateway на VPS, то `claude`, `kimi`, `codex` должны быть установлены на VPS.

Проверки:

```bash
claude --version
codex --version
kimi --version
```

### 6. Codex не отвечает?

Для ChatGPT/OAuth режима выбирайте:

```text
Codex default
```

Не API-only модель.

---

## Пост 7. Анонс релиза v1.0.0

**Заголовок:** Planulix v1.0.0: первый публичный релиз

Вышел первый релиз Planulix.

Что внутри:

- macOS desktop app;
- Android APK;
- Linux gateway для VPS;
- поддержка Claude Code, Kimi Code, Codex CLI, Cursor transcripts;
- список сессий по агентам и проектам;
- чат и файловый проводник;
- диагностика подключения;
- аналитика расходов;
- Tailscale-friendly self-hosted схема.

Скачать:
https://github.com/pyatkovpetr/Planulix/releases/tag/v1.0.0

Репозиторий:
https://github.com/pyatkovpetr/Planulix

Если вы используете CLI-кодеров в нескольких проектах — попробуйте и напишите, какой workflow у вас болит сильнее всего.

Ближайшие задачи:

- улучшать resume для разных CLI;
- полировать desktop UX;
- добавить больше гайдов по установке;
- собрать обратную связь по реальным сценариям.
