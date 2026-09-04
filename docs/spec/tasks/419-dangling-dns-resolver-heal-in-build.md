# 419 — Битый резольвер DNS лечится в сборке, fatal пересборки виден с плашки

| Поле | Значение |
|------|----------|
| Статус | Done (device-check коммита 1 — см. Верификация) |
| Дата старта | 2026-09-05 |
| Дата завершения | 2026-09-05 |
| Коммиты | `e2f0c609` лечение в сборке; коммит 2 — снек fatal с плашки (см. git log §419) |
| Связанные spec'ы | [tasks/121](121-preset-routing-king-dns-orphans.md) (слой D — автосброс резольвера), [tasks/247](247-custom-rule-resolve-action.md) (деградация битого `server` у resolve-правил — образец), [tasks/254](254-detour-cycle-fatal-detector.md) (sheet для fatal-циклов), [tasks/384](384-fakeip-resolver-gate-and-lost-running-snapshot.md), [features/076](../features/076%20settings-and-config-lifecycle/spec.md), [features/417](../features/417%20workspaces/spec.md) (где всплыло) |

## Проблема

На стенде AVD `LxBox_test` после установки §417 плашка «Settings changed — tap
to rebuild config» висела с первого запуска и не снималась ни тапом, ни
временем; VPN при этом работал на старом сохранённом конфиге.

Механика: `vars.dns_final` и `vars.dns_default_domain_resolver` =
`ru-direct:yandex_dot` — DNS-сервер пресета «ru-direct». Пресета в правилах
стенда нет (удалён), §121 «routing король» его серверы не эмитит, а выбранный
резольвер остался. Каждая сборка: `Config built` → валидатор →
`DanglingDnsServerRef` (fatal, §141 блокирующая) → `FatalValidationException`
→ конфиг не сохраняется → `configDirty` не снимается → плашка остаётся.

Два дефекта, из-за которых это стало «вечно» и «молча»:

1. **Автосброс битого резольвера (§121 слой D) жил только в
   `DnsController._load`** — срабатывал при открытии экрана DNS Settings.
   Билдер и bootstrap его не делали: пользователь, удаливший пресет и не
   заходивший в DNS, получал перманентный fatal.
2. **Fatal пересборки с плашки не показывался.** `_rebuildConfig`
   (`home_screen.dart`) при `generateConfig() == null` молча возвращал
   `false`; sheet есть только для `DetourCycle` (§254). Остальные fatal —
   в лог. Пользователь видит плашку, тапает, ничего не происходит.

## Диагностика

- Лог первого запуска (Debug API `/logs/app`): `init: configDirty=true via
  mtime compare` → `bootstrap: entries=true emptyConfig=false dirty=true` →
  `Generating config...` → `Validation: dns.final references missing DNS
  server "ru-direct:yandex_dot"` — до любого действия с Workspaces.
- `/state/storage`: `custom_rules` без единого `kind: preset`;
  `dns_options.servers` без `ru-direct:*`; `vars.dns_final =
  ru-direct:yandex_dot`.
- Тап по плашке на устройстве: две генерации подряд в логе, UI без реакции.
- `git log -S'references missing DNS server'`: валидация fatal с §121 —
  поведение старое, не регрессия §414/§417. §414 лишь сделал mtime-сравнение
  честным; до него `isDirty()` был всегда `true` — плашка вела себя так же.

## Решение

### Коммит 1 — лечение в сборке

[`post_steps/heal_dangling_dns_resolvers.dart`](../../../app/lib/services/builder/post_steps/heal_dangling_dns_resolvers.dart)
— post-step по образцу §247 `healDanglingResolveServers`, зовётся в
`buildConfig` перед `validateConfig`:

- `dns.final` / `route.default_domain_resolver`, которых нет в собранном
  `dns.servers`, заменяются дефолтом шаблона (`local_dns_resolver` /
  `cloudflare_udp` — §121 п. 6: оба всегда в каталоге); если дефолт не
  эмитится — первым эмитированным сервером, пригодным как резольвер (не
  `fakeip`/`hosts`, §384). Ни одного пригодного — не трогаем, валидатор
  говорит своё.
- Замена уходит в `BuildResult.generatedVars` (`dns_final` /
  `dns_default_domain_resolver`) → `SubscriptionController._generate`
  персистит её тем же циклом, что `clash_secret`: следующая сборка чистая,
  экран DNS показывает то же значение, что применено.
- `emitWarnings`: `dns.final reset to "local_dns_resolver": DNS server
  "ru-direct:yandex_dot" is gone (its preset was disabled or removed).`

Слой D в `DnsController` остаётся — он лечит то же самое для экрана.

### Коммит 2 — fatal виден с плашки

`_rebuildConfig` при `config == null` и `!silent`: снек с текстом
`_subController.lastError` (для `DetourCycle` по-прежнему sheet §254, снек не
дублируется). Тихий bootstrap (`silent: true`) не трогаем — там своя
плашка.

## Риски и edge cases

- Пользователь **осознанно** выбрал резольвером сервер пресета и выключил
  пресет: раньше — вечный fatal, теперь — тихий сброс на дефолт с
  предупреждением в логе и снеком при ручной пересборке. Сброс — тот же, что
  §121 делал при открытии DNS Settings.
- Config Editor / импорт JSON с литеральным битым `dns.final`: лечится так
  же; var `dns_final` при этом переписывается — для конфига из редактора это
  ожидаемо (сборка всегда идёт из vars).
- `setVar('dns_final')` — config-var (§113) → поднимает `configDirty`
  внутри `_generate`; `generateConfig` снимает флаг после успешной сборки
  (композиция не менялась) — как для любого generatedVar.

## Верификация

- `test/builder/heal_dangling_dns_resolvers_test.dart`: живые ссылки не
  трогаются; обе битые → дефолты + var-имена; дефолт не эмитится → первый
  пригодный, `fakeip`/`hosts` мимо; только непригодные → no-op; пустое поле
  и отсутствие `dns` → no-op.
- `test/builder/validator_test.dart`, `dns_group_test.dart` — валидатор
  по-прежнему ставит `DanglingDnsServerRef` при прямом вызове (post-step
  лечит ДО него только в `buildConfig`).
- Device (AVD `LxBox_test`, состояние с битым `ru-direct:yandex_dot`):
  пересборка проходит, плашка снимается, в vars `dns_final =
  local_dns_resolver`; снек при ручной пересборке с искусственно
  сломанным конфигом.

## Docs to update

- `CHANGELOG.md` — Unreleased / Fixed.
- `docs/STORAGE.md` — нет (форма vars не меняется).
