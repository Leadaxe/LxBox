# 665 — Фрагментация TLS наследуется всеми узлами, REALITY без исключения; нотис у узла о наследовании

Статус: In progress (18.10.2026). Источник: обсуждение issue #170 (Alex01d)
с владельцем 18.10.2026; отменяет правило §627, уточняет §636 и §664.

## Проблема

§627 сделал из серверной проблемы одного провайдера (REALITY-сервер не
принимал резаный ClientHello) правило для всего класса REALITY: уровни выше
узла (глобальный, папка, подписка) ему не фрагментируют, только флаг на самом
узле. Фрагментация же отвечает на свойство сети пользователя, а не сервера:
DPI оператора одинаков для всех его узлов, и пользователь ждёт, что
глобальный «On» работает везде. Issue #170 показал обратное: REALITY-узел
автора без фрагментации не ходил, а глобальная настройка его не касалась.

Решение владельца: исключение снять; серверная нетерпимость к резаному
ClientHello закрывается «Off» на узле или источнике (уровни §636 уже это
умеют); узел, которому фрагментация пришла сверху, об этом говорит.

## Решение

1. **Сборка.** В `applyTlsFragment` (`tls_transforms.dart`) убрать ветку
   «§627/§636 — REALITY только по флагу узла»: `addFragment`/`addRecord`
   для REALITY считаются как для любого узла, по цепочке
   `node ?? source ?? global`. Комментарий §636 над функцией про REALITY
   убрать. Прочее (`detour` пропускается, `fieldAllowedOn`, masque,
   `fallback_delay` §606) — как было.
   Пинг и тест узла (§636 «те же уровни») — проверить, что они берут
   политику тем же кодом и отдельной ветки про REALITY у них нет; если есть —
   снять так же.

2. **UI узла** (`tls_policy_tiles.dart`, `node_settings_screen.dart`).
   - Снять §664: параметр `reality` у `TlsPolicyTiles`, строки
     «Default (Off — not inherited by REALITY)», «Inherited: Off (REALITY
     ignores …)», подсказку «REALITY: global, folder and subscription
     fragmentation are not applied…» — из кода и из l10n (ru, zh).
     `_reality`/`_isRealityBody` в экране — убрать.
   - Нотис о наследовании: когда у узла хотя бы одно из полей `fragment`,
     `record_fragment` эффективно «On» **не своим флагом** (своё значение
     `null`, унаследованное `true`), под заголовком секции TLS строка по
     образцу подписи detour:
     `Fragmentation is inherited from the %s level. If this server does not
     accept a split ClientHello, set it to Off here.` — `%s` ∈ `global`,
     `folder`, `subscription` (уровень, откуда пришло `true`; если оба поля
     с разных уровней — уровень поля `record_fragment`).
     Не показывать, если `_underDetour` (там уже «Not applied: …»).
   - Строки — английские, l10n по `docs/l10n.md` для всех языков файла.

3. **Источники** (`subscription_settings_tab.dart`): код не менять; убедиться,
   что подпись у поля при «Off» говорит «Off» (а не «Default …»). Если так —
   ничего не делать.

4. **Доки.** В `docs/spec/tasks/627-reality-no-global-fragment.md` в шапку
   статус: «Отменено §665 (18.10.2026)» с одной строкой почему. В §664 —
   строка «Снято §665». В `docs/ARCHITECTURE.md` / `docs/spec/features`, где
   описано исключение REALITY (grep `REALITY` + `fragment`), поправить на
   «наследуется как все». CHANGELOG `[Unreleased]`: запись §664 заменить
   записью §665 (EN+RU) с явным предупреждением: *у кого REALITY-сервер не
   принимает резаный ClientHello, после обновления поставить Off на узле или
   подписке*.

## Проверка

- `app/test/builder/tls_fragment_reality_test.dart`: тест «REALITY-узел
  остаётся без полей фрагментации» перевернуть: при глобальном `true`
  REALITY получает `fragment`/`record_fragment`; `false` на узле снимает;
  `false` на источнике снимает. Точечный прогон одного файла.
- `app/test/widgets/tls_policy_tiles_reality_test.dart` переписать под
  нотис: инherited `true` с папки → нотис со словом `folder`; своё `true` →
  нотиса нет; всё `null`/`false` → нотиса нет. Точечный прогон.
- Эмулятор не гоняем, владелец проверит на телефоне после rc.
