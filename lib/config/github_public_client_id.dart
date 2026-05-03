/// Публичный Client ID **GitHub OAuth App** (не GitHub App). Это не секрет.
///
/// Ошибка `incorrect_client_credentials` при **верном** Client ID: у GitHub на шаге обмена кода
/// обязателен **Client Secret**. Секрет в бинарник не кладём: по умолчанию на десктопе — **device flow**
/// (код на github.com/login/device); PKCE с авто-редиректом на localhost — только если при сборке
/// задано `--dart-define=GITHUB_OAUTH_CLIENT_SECRET=…`, либо используйте серверный OAuth на Planulix.
///
/// Если подозреваете опечатку в ID — сверьте с OAuth Apps на GitHub, без пробелов.
///
/// Чтобы пользователю **не вводить** ID в UI:
/// 1. Создайте [OAuth App](https://github.com/settings/developers).
/// 2. **Authorization callback URL** (одна строка): `http://127.0.0.1:54801/planulix-github-callback`
///    — значение из [githubPkceCallbackUrl] в `lib/services/github_pkce_browser.dart`.
/// 3. Вставьте **Client ID** в [kGithubEmbeddedOAuthClientId] ниже (или соберите с
///    `--dart-define=GITHUB_OAUTH_CLIENT_ID=...`).
///
/// Пустая строка — поле ввода в диалоге показывается как раньше.
library;

const String kGithubEmbeddedOAuthClientId = 'Ov23liBKGdmwbL2N4Wb3';
