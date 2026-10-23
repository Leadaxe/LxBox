# 674 — Превью фильтра направления без поднятого туннеля

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата начала | 2026-10-23 |
| Дата конца | 2026-10-23 |
| Коммиты | см. `git log --grep 674` |
| Связанные спеки | [features/026-DIRECTIONS](../features/026-DIRECTIONS/FEATURE.md); [FUNCTIONS/direction-groups-in-config.md](../features/026-DIRECTIONS/FUNCTIONS/direction-groups-in-config.md) |

## Проблема

GitHub issue #171 п.12: «Direction's node filter preview is very much needs to
work with vpn off».

Фильтр направления применяется при **сборке конфига** в Dart (состав селектора
`<tag>`), то есть результат определён хранилищем и не зависит от ядра. Но превью
«какие узлы попадут» берёт кандидатов из снимка групп ядра
(`homeController.state.ccGroups`, `routing_screen.dart:544-556`, комментарий
«Пусто = туннель не поднят»); без туннеля редактор показывает «No node snapshot
(connect to preview)» (`direction_edit_screen.dart:574`). Превью зависит от
того, от чего не зависит результат, — логическая ошибка, а не ограничение.

## Решение

- Источник кандидатов для превью — сборщик, а не ядро: тот же набор тегов, из
  которого `build_config.dart` формирует состав селектора направления до
  применения фильтра (`selectorTags`/`memberSets`, `:572-576`, `:1360-1385`).
  Вынести получение «пула кандидатов направления по хранилищу» в функцию без
  побочных эффектов (без записи, без сети) и использовать её в превью редактора
  и на вкладке Routing.
- Если полный сборщик дорог (тысячи узлов) — считать в `Isolate.run` со
  снимком, как §652; показывать спиннер, не блокировать main.
- При поднятом туннеле превью тоже строится от сборщика (единый источник);
  снимок ядра не нужен для превью. Если на нём держится что-то ещё
  (пинги в превью?) — исполнителю проверить и сохранить.
- Подпись «connect to preview» убрать; пустой результат — «No nodes match».
- Не менять семантику фильтра и состав селектора; это только источник данных
  для отображения.

### Сделано

- Пул кандидатов — та же сборка, остановленная до групп Направлений:
  `_buildConfig` получил `poolSink` (`app/lib/services/builder/build_config.dart:291`),
  при нём кладёт `selectorTags` и возвращает null (`:615`), не доходя до
  `_buildDirectionGroups` и пост-шагов. Пост-шаги DNS пишут хранилище
  (`post_steps/dns_servers.dart:153`, `post_steps/dns_rules.dart:474`), поэтому
  «полный `buildConfig` на снимке» для превью не годился: префикс до пула хранилище
  не читает и не пишет. Публичный вход — `buildDirectionPool` (`build_config.dart:248`).
- `app/lib/services/builder/direction_pool_preview.dart`: `readStoredBuildSettings`
  (`:30`) — чтение настроек сборки из хранилища, теперь общее с
  `SubscriptionController._generate` (`subscription_controller.dart:3082`; засев
  пресетов и каталоги Tailscale остались в `_generate`, превью их не делает);
  `listsForBuild` (`:60`) — наложение `groupDefaults`, как в `_generate`;
  `directionPoolPreview` (`:72`) — `Isolate.run` со снимком `ParseEnvSnapshot`
  (§652; `_install` → публичный `install`, `cache_rehydrate.dart`), ошибка воркера —
  откат на main с предупреждением в журнал (`:83`).
- Routing (`app/lib/screens/routing_screen.dart`): `_refreshNodePool` (`:562`) вместо
  `_allNodeTags` из `ccGroups`; пересчёт при открытии, при уведомлении
  `SubscriptionController` (отсрочка 300 мс), после добавления и удаления Направления
  (тег резервируется сборкой). `_nodeCountFor` (`:553`) — -1, пока пул считается
  (подпись «all nodes»/«filtered», как раньше). Редактор получает тот же future
  (`:620`).
- Редактор (`app/lib/screens/direction_edit_screen.dart`): параметр
  `Future<List<String>> nodePool` вместо `allNodeTags`; пока пул не пришёл — спиннер
  (`:594`), пустой результат фильтра — «No nodes match» (`:601`, l10n ru/zh), иначе
  прежняя строка «matched: X / N nodes». Подпись «connect to preview» снята.
- Третий вход в редактор — фильтр с главного экрана
  (`app/lib/screens/home/widgets/node_list.dart:784`) — тоже от сборщика,
  `_allNodeTagsFromState` удалён.
- Снимок ядра на превью ничего больше не держал: редактор брал из него только теги
  (пингов в превью нет). Подсказка «of N nodes» у Pool size считается от длины пула.
- Пул включает группы источников (узлы автовыбора, свёртки) и цепочки — ровно как
  состав селектора; прежний снимок ядра группы отбрасывал.

## Проверка

- `app/test/builder/direction_pool_preview_test.dart`: пул по фильтру (regex и
  инверсия) = узлы селектора `<tag>` собранного конфига за вычетом `<tag>-auto`,
  `direct-out`, `block` и ссылок на Направления; пул в isolate = пул на main. Тест
  идёт без мока хранилища — косвенная проверка, что пул его не трогает.
- `app/test/screens/direction_edit_pool_preview_test.dart`: редактор без туннеля
  (снимка ядра нет) с пулом сборщика показывает «matched: 3 / 3 nodes», фильтр сужает,
  несовпадение — «No nodes match»; пока пул считается — спиннер.
- `direction_edit_idle_raise_hint_test.dart`, `fold_ui_570_test.dart` — новый параметр.
- На устройстве не проверено.

### Исходные критерии

- Unit: превью без туннеля для направления с фильтром по regex = состав
  `<tag>` в собранном конфиге (минус служебные `-auto`, `direct-out`, `block`,
  «Other directions», если превью показывает только узлы — как сейчас).
- Widget: редактор открыт без туннеля → список узлов, не заглушка.

## Docs to update

- `features/026-DIRECTIONS/FUNCTIONS/*` — превью от сборщика.
- CHANGELOG `[Unreleased]`.
