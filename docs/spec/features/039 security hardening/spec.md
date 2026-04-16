# 039 — Security Hardening

## Статус: Частично реализовано

## Контекст

Статья на Habr ([habr.com/ru/articles/1020080](https://habr.com/ru/articles/1020080/)) описывает критические уязвимости в мобильных VLESS-клиентах:

1. **Локальный SOCKS5 без авторизации** — любой процесс может подключиться к прокси, узнать внешний IP сервера и дампить трафик
2. **Открытый API** — xray/clash API без авторизации позволяет дампить конфиги с ключами и IP серверов
3. **Android приватные пространства** (Knox, Shelter) не изолируют loopback — сканирование портов доступно из sandbox

Эти уязвимости позволяют: обнаружить реальный IP прокси-сервера, украсть subscription credentials, деанонимизировать пользователя.

## Аудит текущего состояния BoxVPN

### Что уже защищено (хорошо)

| Мера | Статус | Детали |
|------|--------|--------|
| TUN-only inbound | ✅ | Нет SOCKS5/HTTP прокси на localhost. Только `tun-in` |
| Clash API на random порту | ✅ | 49152-65535, не стандартный 9090 |
| Clash API secret | ✅ | Автогенерация 32 hex (16 байт, `Random.secure()`) |
| Clash API только localhost | ✅ | `127.0.0.1:port`, не `0.0.0.0` |
| VPN Service not exported | ✅ | `android:exported="false"` + `BIND_VPN_SERVICE` permission |
| BootReceiver not exported | ✅ | `android:exported="false"` |
| Геомаршрутизация | ✅ | Russian domains → direct (не через прокси) |
| Secret visibility toggle | ✅ | Скрыт по умолчанию в VPN Settings |

### Что требует внимания (риски)

#### 1. Clash API доступен с loopback
**Риск**: Средний. Любое приложение на устройстве может сканировать порты localhost и найти Clash API. С secret это сложнее, но:
- Secret хранится в plaintext в `boxvpn_settings.json`
- Файл доступен через `adb` или root
- При `adb backup` secret утекает

**Рекомендации**:
- [ ] Рассмотреть привязку Clash API к Unix socket вместо TCP (если libbox поддерживает)
- [ ] Хранить secret в Android Keystore вместо plaintext файла
- [x] Secret генерируется криптографически безопасным ГПСЧ (`Random.secure()`)

#### 2. Конфиг содержит credentials серверов
**Риск**: Высокий при утечке файла. sing-box конфиг хранит UUID, пароли, ключи серверов.

**Рекомендации**:
- [ ] Шифровать `singbox_config.json` at rest (AES-256, ключ из Android Keystore)
- [ ] Не показывать credentials в Config Editor по умолчанию (маскировать UUID/пароли)
- [x] Config Editor доступен только из drawer (не на виду)

#### 3. Subscription URL содержит credentials
**Риск**: Средний. URL подписки часто содержит токен авторизации.

**Рекомендации**:
- [x] Copy URL доступен через контекстное меню (не отображается на виду)
- [ ] Маскировать URL в списке подписок (показывать только hostname)
- [ ] При Share/Export предупреждать что URL содержит credentials

#### 4. Кэш подписок на диске
**Риск**: Низкий. Кэш в `sub_cache/` содержит raw ответ сервера подписки.

**Рекомендации**:
- [ ] Шифровать кэш или хранить в app-specific encrypted storage
- [x] Кэш в application support directory (не SD card)

#### 5. QUERY_ALL_PACKAGES permission
**Риск**: Низкий (privacy). Позволяет BoxVPN видеть все установленные приложения (для per-app routing).

**Рекомендации**:
- [x] Permission необходим для функционала App Groups
- [ ] Добавить объяснение в Privacy Policy
- [ ] В Google Play может потребоваться обоснование

## Рекомендации по hardening (roadmap)

### Приоритет 1 (критично)

#### 1.1 Валидация Clash API secret при каждом запросе
Убедиться что ClashApiClient всегда отправляет `Authorization: Bearer {secret}` и sing-box его проверяет.

```dart
// Уже реализовано в clash_api_client.dart:
Map<String, String> get _headers => {
  if (_secret.isNotEmpty) 'Authorization': 'Bearer $_secret',
};
```

**Статус**: ✅ Реализовано

#### 1.2 Не логировать credentials
Проверить что в debug логах не утекают UUID, пароли, subscription URL.

**Статус**: Требует аудита

### Приоритет 2 (важно)

#### 2.1 Encrypted storage для secrets
Перенести `clash_secret` и subscription credentials из plaintext JSON в Android Keystore / EncryptedSharedPreferences.

#### 2.2 Маскировка credentials в UI
- Config Editor: маскировать `uuid`, `password`, `private_key` поля
- Subscription list: показывать только hostname, не полный URL
- Subscription detail: URL за spoiler/tap-to-reveal

### Приоритет 3 (рекомендуется)

#### 3.1 Certificate pinning для критичных запросов
Subscription fetch через HTTPS — рассмотреть pinning для известных провайдеров.

#### 3.2 Network security config
Добавить `network_security_config.xml` запрещающий cleartext traffic.

#### 3.3 ProGuard/R8 obfuscation
Убедиться что release build использует R8 минификацию (Flutter default — да).

## Файлы

| Файл | Статус | Что проверять |
|------|--------|--------------|
| `wizard_template.json` | ✅ | Clash API только на 127.0.0.1, secret обязателен |
| `config_builder.dart` | ✅ | `_ensureClashApiDefaults` — random port + secret |
| `clash_api_client.dart` | ✅ | Authorization header с secret |
| `AndroidManifest.xml` | ✅ | Services not exported, permissions минимальны |
| `settings_storage.dart` | ⚠️ | Plaintext JSON — рассмотреть шифрование |
| `source_loader.dart` | ⚠️ | Кэш в plaintext — рассмотреть шифрование |
| `subscription_fetcher.dart` | ✅ | HTTPS, timeout, size limit |

## Критерии приёмки

- [x] Нет SOCKS5/HTTP inbound на localhost
- [x] Clash API на рандомном порту с обязательным secret
- [x] VPN Service android:exported=false
- [x] Secret генерируется через Random.secure()
- [x] Authorization header во всех Clash API запросах
- [x] Геомаршрутизация RU domains → direct
- [ ] Аудит логов на утечку credentials
- [ ] Encrypted storage для secrets (Keystore)
- [ ] Маскировка credentials в Config Editor
- [ ] network_security_config.xml
