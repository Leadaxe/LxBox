# 016 — Android 14 typed startForeground + specialUse FGS permission

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата | 2026-04-29 |
| Коммиты | `97f87db` |
| Связанные | targetSdk 34, BoxVpnService FGS lifecycle |

## Проблема

На Android 14 (API 34, `targetSdk = 36` у нас) Google требует **typed** `Service.startForeground` с явным `foregroundServiceType` — иначе при старте sing-box тоннеля строгие OEM-сборки (One UI 6, MIUI 14, ColorOS) бросают `MissingForegroundServiceTypeException`. У VPN-сервиса со специфическим назначением единственный валидный тип — `FOREGROUND_SERVICE_TYPE_SPECIAL_USE`, и под него нужно отдельное permission `FOREGROUND_SERVICE_SPECIAL_USE` (появилось в API 34).

Текущий `ServiceNotification.startForeground(NOTIFICATION_ID, notification)` (legacy 2-arg API) на API 34+ срабатывал у части юзеров с sigfault или silent-fail.

## Решение

### Manifest

```xml
<!-- specialUse FGS-type появился в Android 14 (API 34). На младших API
     permission не запрашивается — minSdkVersion="34" гейтит его только
     для устройств где он реально что-то значит. -->
<uses-permission
    android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"
    android:minSdkVersion="34" />

<service
    android:name=".vpn.BoxVpnService"
    android:foregroundServiceType="specialUse"
    ...>
```

### ServiceNotification.kt

```kotlin
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
    service.startForeground(
        NOTIFICATION_ID,
        notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
    )
} else {
    service.startForeground(NOTIFICATION_ID, notification)
}
```

API 34+ → typed-overload, младшие → legacy 2-arg (typed-overload в SDK либо отсутствует, либо не делает ничего полезного).

## Верификация

- На Android 14+ устройстве (тестово — Pixel emulator API 34) — старт сервиса проходит, `Started` приходит без `RemoteException`/`MissingForegroundServiceType`.
- На Android 11/12 устройстве (test phone) — legacy путь, всё работает.
- Manifest: `aapt2 dump badging app-release.apk | grep specialUse` подтверждает declared type.

## Риски

- Если в будущем Google ужесточит требования к `specialUse` (требовать reasoning через `<property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE">`) — нужно добавить. Сейчас не требуется, но мониторим Android dev preview изменения.
