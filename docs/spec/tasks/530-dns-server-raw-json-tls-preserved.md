# 530 — правка SNI в форме DNS-сервера затирает остальной `tls`

| Поле | Значение |
|------|----------|
| Статус | **Spec** (код не писан), ожидает реализации |
| Дата старта | 2026-09-24 |
| Дата завершения | — |
| Issue | #119 «DoH/H3 DNS server options» (`udp_fragment`, ALPN, certificate, reverse mapping) — дефект найден при разборе обходного пути, предложенного в ответе |
| Коммиты | спека — ветка `task-529` |
| Связанные spec'ы | §117 задача 4b (форма inline-сервера), §411 (`quic`/`h3` в форме), §312 (группа), §435 (`tailscale`), §454/§455 (`rawSource` и дословный JSON узлов), issue #140 / `TlsSpec.passthrough` (тот же класс дефекта у узлов — прецедент решения) |

---

## Проблема

Форма DNS-сервера выставляет из `tls` ровно одно поле — SNI
(`app/lib/screens/dns_server_edit/sections/server_form_section.dart:215`,
`«TLS server name (SNI) — optional»`). Всё остальное, что ядро принимает в
`tls` у DoT/DoH/DoQ/DoH3 (`alpn`, `certificate`, `certificate_path`,
`insecure`, `min_version`/`max_version`, `utls`, `ech`, …), выставить формой
нельзя — единственный путь у `ServerKind.inline` это JSON-вкладка
(`app/lib/screens/dns_server_edit/tabs/json_tab.dart:30`).

Этот путь хрупок: **любое** касание поля SNI в форме выбрасывает объект `tls`
целиком и собирает новый из двух ключей.

```dart
// app/lib/screens/dns_server_edit/edit_controller.dart:616-625
void onSniChanged(String raw) {
  final sni = raw.trim();
  if (sni.isEmpty) {
    _body.remove('tls');
  } else {
    _body['tls'] = {'enabled': true, 'server_name': sni};   // ← replace, не merge
  }
  _syncJsonFromBody();
  notifyListeners();
}
```

Сценарий потери (без единого сообщения об ошибке):

1. пользователь вписывает на JSON-вкладке `tls: {enabled, server_name, alpn,
   certificate}`;
2. возвращается на вкладку параметров и правит SNI (хоть на один символ);
3. `onSniChanged` пишет `{'enabled': true, 'server_name': …}` — `alpn` и
   `certificate` исчезли;
4. `_syncJsonFromBody` (`edit_controller.dart:638-641`) немедленно
   перерисовывает текст JSON-вкладки из `_body`, то есть **обрезанная** версия
   становится видимым содержимым, и откатиться уже нечем;
5. Save пишет усечённое тело.

User-impact: пока полей нет в форме (см. ниже про §529), JSON-вкладка —
единственный способ задать свой корневой CA или ALPN для DNS-сервера, и она
не держит правку рядом стоящего поля. Это ровно то, что у **узлов** уже
чинили: issue #140, `tls.certificate` терялся на Save, потому что модель ключа
не знала — решением стал allowlist сквозных ключей
(`app/lib/models/tls_spec.dart:25-40` `kTlsPassthroughKeys`, комментарий
`tls_spec.dart:145-155`). У DNS-серверов аналога нет.

## Диагностика

Почему дефект пережил ревью: у DNS-сервера **нет типизированной модели тела**.
`DnsServerInline.body` — сырая карта (`app/lib/models/dns_ref.dart:62`,
`final Map<String, dynamic> body`), и она сохраняется дословно. То есть
хранилище и эмиттер лишние ключи не теряют — терял ровно один сеттер формы.
Поэтому ни один корпусной/round-trip тест дефект не видит: он проявляется
только через последовательность «JSON → форма».

Проверено, что случай единственный. Все записи в `_body` из контроллера —
скаляры (`server`, `server_port`, `path`, `domain_resolver`, `detour`, `type`,
`endpoint`, `mode`, `error_ttl`, `win_ttl`, `accept_default_resolvers`), и
единственный **вложенный объект**, который контроллер собирает целиком, —
`tls` на строке 621. `_body['servers'] = members`
(`edit_controller.dart:479`) тоже replace, но это корректно: список членов
группы формой и владеется, частичного состояния у него нет.

Отдельно — три места, где `tls` **удаляется**, и все три обоснованы, чинить их
не нужно:

- `edit_controller.dart:619` — SNI очищен пользователем. Спорно (см. «Риски»);
- `edit_controller.dart:416` — уход в безадресный режим (`group`/`tailscale`,
  `kDnsAddresslessModes`, `edit_controller.dart:33`): у этих типов TLS-блока в
  ядре нет вовсе (`GroupDNSServerOptions`,
  `/Users/macbook/projects/sing-box-lx/option/dns.go:227-232` — только
  `servers`/`mode`/`error_ttl`/`win_ttl`, без `DialerOptions` и без
  `OutboundTLSOptionsContainer`);
- `edit_controller.dart:440` — переход в `udp`: `RemoteDNSServerOptions`
  (`option/dns.go:188-191`, регистрация `dns/transport/udp.go:28`)
  TLS-контейнера не несёт.

## Решение

**Merge вместо replace в `onSniChanged`.** Если `_body['tls']` уже объект —
править в нём только `server_name` (и держать `enabled: true`), прочие ключи
не трогать:

```dart
final prev = _body['tls'];
final next = prev is Map ? Map<String, dynamic>.from(prev) : <String, dynamic>{};
next['enabled'] = true;
next['server_name'] = sni;
_body['tls'] = next;
```

**Пустой SNI — не удалять объект, а удалять ключ.** Убрать из `tls` только
`server_name`; если после этого в объекте не осталось ничего, кроме
`enabled`, — снять `tls` целиком (прежнее поведение для обычного случая
сохраняется байт в байт). Иначе `tls` остаётся с `alpn`/`certificate` и
`enabled: true`: у DoT/DoH/DoQ/DoH3 ядро TLS включает само
(например `dns/transport/quic/quic.go:49`: `tlsOptions.Enabled = true`),
так что объект без `server_name` валиден и осмыслен.

Инвариант, который проверяет тест: **контроллер не удаляет и не переписывает
ни один ключ `tls`, которого он не выставляет сам.** Собственные у него два —
`enabled` и `server_name`.

Смены модели, хранилища, эмиттера и контракта не требуется: тело инлайн-сервера
уже сквозное (`dns_ref.dart:62`). Правка локальна — один метод контроллера.

### Что НЕ входит

- **Поля в форме** (ALPN, certificate, `udp_fragment`, `reverse_mapping` из
  issue #119) — отдельный вопрос, решение владельца по §529 ожидается. §530
  нужен независимо от него: даже когда часть полей появится в форме, у `tls`
  останутся ключи, которых форма не выставляет (`utls`, `ech`,
  `min_version`, …), и они обязаны переживать правку соседнего поля.
- Три обоснованных `remove('tls')` (416/440 и очистка при смене типа) — см.
  «Диагностика», поведение верное.
- Шаблонные и пресетные серверы (`ServerKind.template`/`preset`) — JSON-вкладка
  у них read-only (`json_tab.dart:30`), дефект недостижим.

## Риски и edge cases

- **Пустой SNI при непустом `tls`** — меняется наблюдаемое поведение: раньше
  блок исчезал, теперь остаётся. Это и есть цель правки, но случай попадает в
  тест явно, чтобы изменение было осознанным.
- **`tls` не объект** (пользователь вписал `"tls": true` или строку) — merge
  должен деградировать в прежний replace, а не падать. Проверка `is Map`
  обязательна; в тест идёт отдельным кейсом.
- **`tls` с `enabled: false`** — контроллер выставляет `enabled: true`, как и
  раньше. Держать чужое `false` при заданном SNI смысла нет: ядро у
  DoT/DoH/DoQ/DoH3 включает TLS всё равно.
- Golden-эталоны сборки (§439) не должны шевельнуться: правка не касается
  ни шаблона, ни эмиттера. Изменившийся golden = сигнал, что задето лишнее.

## Верификация

- Новый кейс в `app/test/screens/dns_server_edit/edit_controller_test.dart`:
  тело с `tls: {enabled, server_name: 'a.example', alpn: ['h2','h3'],
  certificate: '-----BEGIN…'}` → `onSniChanged('b.example')` → в `_body['tls']`
  `server_name == 'b.example'`, **`alpn` и `certificate` на месте**. Контрольный
  прогон против текущего кода — тест должен падать (иначе он вакуумный).
- Кейсы на edge cases: пустой SNI при лишних ключах (`tls` остаётся без
  `server_name`); пустой SNI при `tls` только из `enabled`/`server_name`
  (`tls` уходит, как раньше); `tls` не-объект (replace, без исключения).
- Кейс на сквозной путь JSON → форма: `onBodyTextChanged`
  (`edit_controller.dart:672`) с сырым JSON, затем `onSniChanged`, затем чтение
  `bodyCtrl.text` — лишние ключи должны быть в видимом тексте вкладки, а не
  только в `_body`.
- Регрессия существующих: `edit_controller_test.dart`, `json_tab_test.dart`,
  `tailscale_mode_test.dart`, `dns_group_edit_controller_test.dart`,
  `dns_controller`, `golden_config`, `golden_storage_roundtrip`.
- `flutter analyze` — чисто. l10n не затрагивается (новых строк нет).
- Контракт (`app/contract/registry`, зеркало 1.1.52) не затрагивается:
  правка в UI-контроллере, реестр DNS-сервера не описывает.

## Нерешённое / follow-up

- §529 (если владелец её заведёт) — сами поля TLS/`udp_fragment` и глобальный
  `reverse_mapping` в UI. Порядок не важен: §530 самостоятелен.
- Общий вопрос той же природы — **у формы DNS-сервера нет типизированной
  модели тела**, инвариант «не трогай чужие ключи» держится только на ревью
  каждого сеттера. Аналог `kTlsPassthroughKeys` (§454) для DNS-серверов не
  заводился; если сеттеров вложенных объектов станет больше одного, вопрос
  придётся ставить всерьёз.
