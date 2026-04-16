# 030 — URL Launcher

**Status:** Реализовано

## Контекст

В нескольких экранах (subscriptions, subscription detail) дублировался код открытия URL. На Android нужен Intent.ACTION_VIEW через platform channel. Требуется единый сервис.

## Реализация

### Сервис UrlLauncher

Класс `UrlLauncher` со статическим методом `open(String url)`. Использует `MethodChannel` для вызова нативного Android кода:

```dart
class UrlLauncher {
  static const _channel = MethodChannel('com.leadaxe.boxvpn/utils');

  static Future<void> open(String url) async {
    try {
      await _channel.invokeMethod('openUrl', {'url': url});
    } catch (e) {
      // Fallback: копируем URL в буфер обмена
      await Clipboard.setData(ClipboardData(text: url));
    }
  }
}
```

### Android сторона

В `MainActivity.kt` регистрируется обработчик MethodChannel:

```kotlin
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.leadaxe.boxvpn/utils")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                        startActivity(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
```

### Fallback

Если `invokeMethod` выбрасывает исключение (например, нет приложения для обработки URL или platform channel недоступен), URL копируется в буфер обмена и показывается SnackBar с сообщением.

### Замена дублированного кода

Прямые вызовы clipboard/intent в экранах заменены на `UrlLauncher.open(url)`:
- `SubscriptionsScreen` — открытие URL подписки
- `SubscriptionDetailScreen` — открытие ссылок support/web page

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/services/url_launcher.dart` | **Новый** — сервис UrlLauncher с MethodChannel |
| `android/app/src/main/kotlin/.../MainActivity.kt` | Регистрация MethodChannel handler для openUrl |
| `lib/screens/subscriptions_screen.dart` | Замена дублированного кода на `UrlLauncher.open()` |
| `lib/screens/subscription_detail_screen.dart` | Замена дублированного кода на `UrlLauncher.open()` |

## Критерии приёмки

- [x] Класс UrlLauncher с методом `open(url)`
- [x] MethodChannel `com.leadaxe.boxvpn/utils` зарегистрирован в MainActivity
- [x] Android вызывает Intent.ACTION_VIEW для URL
- [x] Fallback на копирование в буфер при ошибке
- [x] Дублированный код в экранах заменён на единый сервис
