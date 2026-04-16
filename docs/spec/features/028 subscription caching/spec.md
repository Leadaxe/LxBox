# 028 — Subscription Caching

**Status:** Реализовано

## Контекст

При отсутствии сети обновление подписки приводило к ошибке, счётчик узлов сбрасывался, статус показывал "Error". Пользователь терял информацию о ранее загруженных узлах. Нужно кеширование ответов для offline-устойчивости.

## Реализация

### Кеш на диске

Сырой HTTP-ответ (тело подписки) сохраняется в директорию `sub_cache/` внутри application support directory. Имя файла — hex-представление `hashCode` URL подписки:

```dart
String _cacheKey(String url) => url.hashCode.toRadixString(16);
String _cachePath(String url) => '${appSupportDir.path}/sub_cache/${_cacheKey(url)}';
```

### Логика в SourceLoader

При загрузке подписки:

1. HTTP запрос на URL
2. **Успех:** сохранить ответ в кеш (перезаписать), парсить, вернуть узлы
3. **Ошибка сети:** прочитать из кеша, если кеш есть — парсить, вернуть узлы + флаг `fromCache: true`
4. **Ошибка сети + нет кеша:** вернуть пустой результат с ошибкой

```dart
Future<LoadResult> loadSource(ProxySource source) async {
  try {
    final response = await _httpGet(source.url);
    await _writeCache(source.url, response.body);
    final nodes = _parse(response.body);
    return LoadResult(nodes: nodes);
  } catch (e) {
    final cached = await _readCache(source.url);
    if (cached != null) {
      final nodes = _parse(cached);
      return LoadResult(nodes: nodes, fromCache: true, error: e.toString());
    }
    return LoadResult(nodes: [], error: e.toString());
  }
}
```

### SubscriptionController

При получении `LoadResult` с `fromCache: true`:
- Счётчик узлов **не сбрасывается** — показывает количество из кеша
- Статус отображается как `"N nodes (update failed)"` вместо `"Error"`
- Последняя дата обновления не обновляется (остаётся прежней)

### Директория кеша

Создаётся при первом использовании. Не очищается автоматически. При удалении подписки соответствующий кеш-файл удаляется.

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/services/source_loader.dart` | Запись/чтение кеша, fallback на кеш при ошибке |
| `lib/controllers/subscription_controller.dart` | Обработка `fromCache`, формирование статуса |

## Критерии приёмки

- [x] HTTP ответ подписки кешируется на диск в `sub_cache/`
- [x] Ключ кеша — hex hashCode URL
- [x] При сетевой ошибке данные загружаются из кеша
- [x] Счётчик узлов не сбрасывается при ошибке обновления
- [x] Статус показывает "N nodes (update failed)" при использовании кеша
- [x] При успешном обновлении кеш перезаписывается
- [x] При удалении подписки кеш-файл удаляется
