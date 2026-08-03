/// §357 — псевдопротокол `lxbox://` в кнопках support-ленты.
///
/// Грамматика: `lxbox://<action>:<payload>` — действие отделено от аргумента
/// ДВОЕТОЧИЕМ: payload — сырая строка «всё после первого `:`», поэтому
/// аргументом может быть целый URI со слешами/query/фрагментом
/// (`lxbox://add:vless://uuid@host:443?…#имя`). `Uri.parse` НЕ используется —
/// он видит в `route:dns` пару host:port; парсим строкой.
///
/// v1-действия:
/// - `route:<screen>[/<tab>]` — открыть экран приложения (реестр ниже);
/// - `add:<uri>` — открыть Servers с предзаполненным полем ввода (добавление
///   подтверждает сам юзер — авто-add запрещён: support.json приезжает с
///   GitHub, компрометация канала не должна подсовывать юзерам чужой сервер);
/// - `share:<текст>` — системный share-лист (кнопка «поделиться»); экран
///   сообщения НЕ закрывается (юзер возвращается после отправки).
///
/// Forward-compat: неизвестное действие/экран → кнопка НЕ показывается
/// (см. [isResolvableSupportAction]) — новые действия в JSON не ломают
/// старые версии приложения.
library;

import 'package:flutter/foundation.dart';

/// Разобранная lxbox-ссылка: действие + сырой payload.
@immutable
class SupportLinkAction {
  const SupportLinkAction(this.action, this.payload);

  final String action;
  final String payload;

  static const _scheme = 'lxbox://';

  /// null — не lxbox-ссылка (обычный URL) или битая (нет `:`/пустые части).
  static SupportLinkAction? parse(String url) {
    if (!url.startsWith(_scheme)) return null;
    final rest = url.substring(_scheme.length);
    final i = rest.indexOf(':');
    if (i <= 0) return null; // нет действия или нет разделителя
    final payload = rest.substring(i + 1);
    if (payload.isEmpty) return null;
    return SupportLinkAction(rest.substring(0, i), payload);
  }
}

/// Экраны действия `route:` — первый `/`-сегмент payload'а. `profiler` —
/// семантический алиас (сегодня = Debug/Profiling): слаг обозначает
/// назначение, а не место в UI, и переживёт переезд фичи между экранами.
const kSupportRouteScreens = <String>{
  'servers',
  'routing',
  'dns',
  'vpn-settings',
  'app-settings',
  'speedtest',
  'stats',
  'config',
  'debug',
  'about',
  'profiler',
  'donate',
};

/// `route:<screen>[/<tab>[/…]]` → сегменты payload'а.
List<String> routeSegments(SupportLinkAction a) => a.payload.split('/');

/// Может ли ЭТА версия приложения исполнить действие. false → кнопка
/// скрывается молча (forward-compat с будущими действиями в JSON).
bool isResolvableSupportAction(SupportLinkAction a) => switch (a.action) {
      'route' => kSupportRouteScreens.contains(routeSegments(a).first),
      'add' => a.payload.trim().isNotEmpty,
      'share' => a.payload.trim().isNotEmpty,
      _ => false,
    };

/// §357 — действия, которые НЕ уводят с экрана сообщения (как https-кнопки:
/// юзер может поделиться и остаться, потом нажать «Прочитал»).
bool isInPlaceSupportAction(SupportLinkAction a) => a.action == 'share';
