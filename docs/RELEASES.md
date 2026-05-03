# Planulix Releases

Готовые сборки публикуются на странице GitHub Releases:

- Latest release: https://github.com/pyatkovpetr/Planulix/releases/latest
- v1.0.0: [docs/releases/v1.0.0.md](releases/v1.0.0.md)

## Что скачивать

- `Planulix-macOS-<version>.zip` — macOS desktop app.
- `Planulix-Android-<version>.apk` — Android APK для ручной установки.
- `planulix-gateway-linux-*.tar.gz` — Linux gateway для VPS/self-hosted установки.
- `SHA256SUMS.txt` — контрольные суммы для desktop/mobile assets.

## Публикация релиза

Перед публикацией:

```bash
flutter build macos --release --no-tree-shake-icons
flutter build apk --release
```

Затем упакуйте `.app`, приложите APK, checksums и загрузите assets через GitHub Releases.
