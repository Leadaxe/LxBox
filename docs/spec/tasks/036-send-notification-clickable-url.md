# 036 — `sendNotification` implementation: показывать notification с clickable URL

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-05-06 |
| Связанные | [`035 platform interface extras`](035-platform-interface-extras-in-debug-api.md) |

## Цель

Реализовать `PlatformInterface.sendNotification(notification)` callback в `BoxVpnService.kt`. Сейчас это no-op (только `Log.d`). Sing-box зовёт его когда какой-то outbound просит юзера авторизоваться через внешний URL — на текущий момент **только Tailscale outbound** (см. `protocol/tailscale/endpoint.go:438`).

После реализации — sing-box сможет показывать system notification с clickable carddef-target'ом который открывает browser → юзер делает OAuth → tailscale outbound становится active.

## Что приходит в callback

`io.nekohasekai.libbox.Notification`:

```
identifier  String      "tailscale-authentication" — channel id
typeName    String      "Tailscale Authentication Notifications" — channel name
typeID      int         10 — notification id (для replace при duplicate)
title       String      "Tailscale Authentication"
subtitle    String      (не используется в Tailscale случае)
body        String      "Tailscale outbound[<tag>] is waiting for authentication."
openURL     String      "https://login.tailscale.com/a/xxxx" — OAuth flow URL
```

## Реализация

### 1. `BoxVpnService.kt` — заменить existing no-op

Существующий код:
```kotlin
override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
    Log.d(TAG, "Notification: ${notification.title}")
}
```

Заменить на полную имплементацию:

```kotlin
override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
    val context = applicationContext
    val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    val channelId = notification.identifier.ifBlank { "lxbox-core" }
    val channelName = notification.typeName.ifBlank { "Core notifications" }

    // 1. Channel — idempotent на каждый вызов (createNotificationChannel
    //    игнорирует если канал уже есть с таким id).
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        val channel = NotificationChannel(
            channelId,
            channelName,
            NotificationManager.IMPORTANCE_HIGH,
        )
        nm.createNotificationChannel(channel)
    }

    // 2. PendingIntent для tap → browser. ACTION_VIEW + http(s) URI ⇒
    //    Android запустит default-browser с этим URL.
    val pendingIntent: PendingIntent? = if (notification.openURL.isNotBlank()) {
        runCatching {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(notification.openURL)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            PendingIntent.getActivity(
                context,
                notification.typeID,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }.getOrNull()
    } else null

    // 3. Build notification.
    val builder = NotificationCompat.Builder(context, channelId)
        .setSmallIcon(R.drawable.ic_stat_lxbox)              // уже используется FGS
        .setContentTitle(notification.title)
        .setContentText(notification.body)
        .setPriority(NotificationCompat.PRIORITY_HIGH)
        .setAutoCancel(true)
    if (notification.subtitle.isNotBlank()) {
        builder.setSubText(notification.subtitle)
    }
    if (pendingIntent != null) {
        builder.setContentIntent(pendingIntent)
    }

    // 4. Show. typeID — id для notify() ⇒ повторный вызов с тем же id
    //    обновляет existing notification вместо stacking'а.
    runCatching {
        nm.notify(notification.typeID, builder.build())
    }.onFailure {
        Log.e(TAG, "sendNotification.notify failed", it)
    }

    // Дубль в commandServer log — для observability через /logs (spec 031).
    // Юзер видит URL даже если permission denied и notification не показалась.
    Log.d(TAG, "Notification: ${notification.title} → ${notification.openURL}")
    commandServer?.writeMessage(
        0,
        "platform notification: ${notification.title} (${notification.openURL})",
    )
}
```

Imports которые понадобятся (если ещё не подключены в файле):
```kotlin
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
```

`R.drawable.ic_stat_lxbox` — иконка которую уже использует foreground service. Если в проекте под другим именем — взять оттуда.

### 2. Manifest — `POST_NOTIFICATIONS` permission

В `AndroidManifest.xml` (`app/android/app/src/main/AndroidManifest.xml`) добавить:

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

На API ≥ 33 (Android 13) это **runtime permission**. Без него `nm.notify()` тихо ничего не показывает (но не падает). Запрашивать прямо при tailscale-выпадении — overengineering, поэтому:

- Permission **declared в manifest** → юзер увидит его в App Info → Permissions, может разрешить вручную.
- Если не разрешён — fallback через `commandServer.writeMessage` (URL логируется, виден через `/logs?source=core`).

Запрос permission'а из UI можно сделать в отдельной задаче (показывать `PermissionRequest` rationale → `requestPermissions` → handle result), но не блокирует core фичу.

### 3. UI запрос permission'а — отложено

Не в этой таске. Достаточно declared в manifest. Юзеру при первом срабатывании:
1. Без permission → notification не показывается, URL в `/logs?source=core` через debug API
2. После того как юзер вручную разрешил в Settings → следующий sendNotification work'ает

## Test plan

### Подготовка (вручную через adb)

1. Поставить APK с этой имплементацией.
2. Через debug API rebuild config с tailscale outbound в составе:

```bash
TOKEN=357f5aacdf154419d2787ec61e3ad9f2

# Получить текущий config
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9270/state/storage \
  > /tmp/storage.json

# Manually create config with tailscale outbound — добавить в outbounds:
# {
#   "type": "tailscale",
#   "tag": "tailscale-out",
#   "state_directory": "/data/data/com.leadaxe.lxbox/files/tailscale-test"
# }

# Можно через Debug API: PUT /clash/configs или прямое модифицирование
# config'а в storage. Конкретный путь зависит от того как мы хотим тестировать —
# проще поправить шаблон вручную и rebuild через /action/rebuild-config.
```

3. Connect VPN с этим конфигом → sing-box запускает tailscale outbound → инициализация → ждёт auth → callback `sendNotification` срабатывает.

### Чек-листы

| Чек | Ожидаемое |
|---|---|
| Notification появляется в shade | ✓ если permission granted (или API < 33) |
| Title/body соответствуют тому что прислал sing-box | ✓ |
| Тап по notification → открывается browser → URL `login.tailscale.com/a/xxxx` | ✓ |
| `commandServer.writeMessage` пишет URL в core logs | ✓ всегда (независимо от permission) |
| `/logs?source=core` через Debug API показывает URL | ✓ |
| После того как юзер прошёл OAuth в браузере — tailscale outbound становится active без deep link callback в app | ✓ (sing-box polling сам подхватывает) |
| Повторный `sendNotification` с тем же typeID не создаёт второй stack — обновляет existing | ✓ (благодаря `nm.notify(typeID, ...)`) |
| Без `POST_NOTIFICATIONS` permission на API 33+ — ничего не падает, но и не показывается | ✓ |

## Что НЕ в скопе

- **Runtime permission request UI** — declared в manifest, юзер сам разрешает. Дёргать `requestPermissions` из VPN service'а нельзя (нужен Activity); делать прокси через MainActivity — отдельная мелкая таска.
- **In-app surfacing URL** (показать "Authorization pending" в node-editor UI с copy-URL кнопкой) — отдельная фича когда введём Tailscale outbound type в `NodeSpec`.
- **Tailscale outbound model/parser/builder** — это большая фича сама по себе. Сейчас тестируем через **manual config edit**.
- **Deep link callback** на возврат из браузера — не нужен (Tailscale auth flow на polling).

## Risks

| Риск | Митигация |
|---|---|
| `POST_NOTIFICATIONS` denied → юзер не видит auth prompt | URL дублируется в core logs (`commandServer.writeMessage`), доступ через `/logs?source=core` |
| `R.drawable.ic_stat_lxbox` имени нет в проекте | Перед коммитом проверить `app/android/app/src/main/res/drawable/` — взять existing FGS-иконку |
| `notification.openURL` пустой (не Tailscale случай в будущих версиях sing-box) | `pendingIntent = null` → notification без contentIntent (тап не делает ничего) |
| `notification.openURL` malformed → `Uri.parse` exception | `runCatching` ловит, log + null pendingIntent |
| Два разных tailscale outbound'а с одним `typeID = 10` | sing-box использует один `typeID` для всех Tailscale auth events — повторный notify обновит existing. Это правильное поведение (один auth-prompt, не два). |
| Юзер игнорит notification | sing-box продолжает polling — auth можно сделать позже из core logs (URL там есть) |

## План имплементации

1. Добавить `POST_NOTIFICATIONS` в `AndroidManifest.xml`.
2. Заменить `sendNotification` override в `BoxVpnService.kt` на полную имплементацию (см. snippet выше).
3. Добавить imports.
4. Verify `R.drawable.ic_stat_lxbox` существует (или взять существующее имя FGS-иконки).
5. Build APK + install.
6. Smoke-тест через manual config edit (ручная вставка tailscale outbound в config через debug API + connect).
7. Убедиться что URL логируется в core logs независимо от того показалось ли notification.

## Docs to update

См. постоянную карту в [`docs/spec/README.md → Карта обновления документации`](../README.md#карта-обновления-документации).

| Файл | Что добавить |
|---|---|
| [`docs/api/debug-api-reference.md`](../../api/debug-api-reference.md) | Не меняется — это native-only feature, Debug API endpoints не добавляются. (Опционально упомянуть в discussion section что `sendNotification` callback теперь работает.) |
| [`CHANGELOG.md`](../../../CHANGELOG.md) | Entry в `Unreleased`: «sing-box `sendNotification` теперь показывает Android notification с tap-to-OpenURL для Tailscale auth flow». |
| [`docs/ARCHITECTURE.md`](../../ARCHITECTURE.md) | Опционально — заметка в native-side / PlatformInterface section про реализацию sendNotification + NotificationChannel lifecycle. |
| [`RELEASE_NOTES.md`](../../../RELEASE_NOTES.md) + [`docs/releases/vX.Y.Z.md`](../../releases/) | На bump'е версии — entry если sing-box notifications будут видны user'у. Tailscale в продакшене не используется, можно deferred. |
| [`pubspec.yaml`](../../../app/pubspec.yaml) | Patch bump в release-batch'е с §035-§037. |
| `AndroidManifest.xml` | Добавить `POST_NOTIFICATIONS` permission (уже в плане выше — напоминание для checklist'а). |
