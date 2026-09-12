# Planulix Releases

Готовые сборки публикуются на странице GitHub Releases:

- Latest release: https://github.com/pyatkovpetr/Planulix/releases/latest
- v1.1.0: [docs/releases/v1.1.0.md](releases/v1.1.0.md)
- v1.0.0: [docs/releases/v1.0.0.md](releases/v1.0.0.md)

## Что скачивать

- `Planulix-macOS-<version>.zip` — macOS desktop app.
- `Planulix-Android-<version>.apk` — Android APK для ручной установки.
- Gateway для VPS устанавливается скриптом из исходников; новые Linux-сборки CI и их SHA-256 отправляются в админ-канал Telegram, без загрузки в GitHub Actions artifacts и Releases. Старые релизы могут содержать прежние gateway-архивы.
- `SHA256SUMS.txt` — контрольные суммы для desktop/mobile assets.

## Публикация релиза

Перед публикацией:

```bash
flutter build macos --release --no-tree-shake-icons
flutter build apk --release
```

Затем упакуйте `.app`, приложите APK, checksums и загрузите assets через GitHub Releases.

Для отправки gateway-сборок в CI задайте в GitHub Actions secrets репозитория
`PLANULIX_TELEGRAM_BOT_TOKEN` и `PLANULIX_TELEGRAM_CHAT_ID`. Бот должен быть
администратором целевого канала. Если секреты отсутствуют, job сборки завершится
ошибкой без публикации бинарников.
