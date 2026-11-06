# 721 — AppFunctions: включение/выключение VPN и статус туннеля для ИИ-агентов

| Field | Value |
|-------|-------|
| Status | In progress |
| Start date | 2026-11-06 |
| Source | Решение владельца 05.11.2026: «давай сделаем первые две» (включить/выключить VPN, статус туннеля); 06.11 — «делать сейчас», зная про экспериментальный статус API |
| Related specs | §047 (Automation API — тот же приём: мастер-тумблер + нативные START/STOP), §032 (плитка QS), §192 (`has_tun`) |

## Problem

Android 16 даёт приложениям AppFunctions API: приложение объявляет функции,
система индексирует их, ИИ-агент с разрешением `EXECUTE_APP_FUNCTIONS`
(Gemini и системные ассистенты) находит их и вызывает от имени пользователя.
L×Box таких функций не объявляет, поэтому просьба «включи VPN», сказанная
ассистенту, до приложения не доходит.

Google Play с 14.04.2027 вводит для AppFunctions отдельные правила
(«Разрешения и API с доступом к конфиденциальной информации», раздел
AppFunctions API). Они учтены в разделе «Требования Google Play».

## Diagnosis

Сверено с документацией 05–06.11.2026
(developer.android.com/ai/appfunctions, заметки к выпускам
`androidx.appfunctions`, репозиторий android/skills → `device-ai/appfunctions`).

- Библиотека: `androidx.appfunctions:appfunctions` и KSP-процессор
  `androidx.appfunctions:appfunctions-compiler`, версия `1.0.0-rc01` (04.11.2026).
- Форма объявления (с beta01): абстрактный класс-наследник
  `AppFunctionService` с `@AppFunctionServiceEntryPoint(serviceName, appFunctionXmlFileName)`,
  внутри — `suspend`-функции с `@AppFunctionDeclaration(isDescribedByKDoc = true)`.
  KSP порождает конкретный сервис и XML-схему. Старые `@AppFunction` и
  `AppFunctionContext` сняты — не использовать.
- Точка входа в приложении одна (до Android 17 система допускает один сервис
  с действием `android.app.appfunctions.AppFunctionService`).
- Сборка: `compileSdk` ≥ 37 (у нас 36 — значение Flutter по умолчанию),
  KSP в проекте не подключён.
- Манифест: сервис с `android:permission="android.permission.BIND_APP_FUNCTION_SERVICE"`,
  `exported="true"`, свойства `android.app.appfunctions.schema` и
  `android.app.appfunctions.v2`, intent-filter с действием
  `android.app.appfunctions.AppFunctionService`; на уровне application —
  свойство `android.app.appfunctions.app_metadata` → `@xml/app_metadata`
  (`AppFunctionAppMetadata`, атрибут `appfn:instructions`).
- Ошибки агенту: наследники `AppFunctionException`; любое другое исключение
  агент видит как безликое `AppFunctionAppUnknownException`.
- Проверка на устройстве: `adb shell cmd app_function list-app-functions --package …`,
  `execute-app-function`, `set-enabled`.
- Статус API: экспериментальный. Вызывать функции из Gemini сейчас могут
  только приложения из закрытой программы Google (EAP). Пользователи
  изменения не увидят до открытия доступа.

Что уже есть в нативе (движок Flutter не нужен):

- `BoxVpnService.start(context)` / `stop(context)` — прямой старт и остановка
  (`app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt`).
- `BoxVpnService.currentStatus: VpnStatus` — Stopped / Starting / Started / Stopping.
- Проверка согласия перед стартом — образец `LxBoxIntentReceiver.handleToggle`:
  `!BootReceiver.hasTun(ctx) || VpnService.prepare(appCtx) == null`.
- Старт из холодного процесса — образец `BootReceiver.onReceive`:
  `BoxApplication.initialize(context)`, затем `BoxVpnService.start(context)`.
- Мастер-тумблер, включающий компоненты манифеста рантаймом —
  `LxBoxIntentReceiver.setEnabled` + Dart `setAutomationEnabled`
  (`automation_tab.dart`, `automation_sync.dart`).

## Solution

### Функции

Класс `LxBoxAppFunctions` (пакет `com.leadaxe.lxbox.appfunctions`),
`@RequiresApi(36)`, порождаемый сервис — `LxBoxAppFunctionService`.

| Функция | Параметры | Результат | Поведение |
|---------|-----------|-----------|-----------|
| `startVpn` | нет | `VpnState` | Уже Started/Starting — вернуть состояние. Нужен TUN и согласие на VPN не выдано — ошибка с текстом «VPN permission is not granted. Open L×Box and connect once.»; активити НЕ открывать. Нет сохранённого конфига — ошибка «No configuration. Open L×Box and add a server.» Иначе старт по образцу `BootReceiver`, ожидание выхода из переходного состояния не дольше 15 с, вернуть фактическое состояние. |
| `stopVpn` | нет | `VpnState` | Уже Stopped — вернуть состояние. Иначе `BoxVpnService.stop`, ожидание не дольше 15 с, вернуть фактическое состояние. |
| `getVpnStatus` | нет | `VpnState` | Только чтение `currentStatus`. |

`VpnState` — `@AppFunctionSerializable(isDescribedByKDoc = true)`, одно поле
`status: String` со значениями `stopped` / `starting` / `started` / `stopping`.

Имя выбранного сервера в `VpnState` НЕ входит: имена узлов приходят из чужих
подписок, а правила запрещают передавать агенту в ответах текст, который может
быть прочитан как инструкция. Вернёмся к этому отдельным решением.

KDoc функций и `appfn:instructions` — на английском, описывают только то,
что функция делает. Никаких указаний агенту о поведении, о других
приложениях и о порядке выбора инструментов.

Класс ошибки выбирать из наследников `AppFunctionException` в rc01 по смыслу
(нет согласия — «permission required» или ближайший; нет конфига —
«not supported / element not found» или ближайший); свой текст — как в таблице.

### Тумблер (по умолчанию выключено)

Выключение VPN чужой командой — чувствительное действие, поэтому доступ
агентов включает пользователь сам, как в §047.

- App Settings → вкладка Automation, отдельная строка-переключатель
  «AI assistant control» с подписью «Let Android assistants turn the VPN on
  or off and read its status (Android 16+)». На Android < 16 строка скрыта.
- Хранение — по правилу «Где живут настройки» (`docs/ARCHITECTURE.md` § 5),
  рядом с настройкой автоматизации.
- Натив: пока тумблер выключен, функции агенту недоступны. Способ выбрать
  по факту на устройстве: (а) сервис в манифесте `android:enabled="false"` и
  включение через `PackageManager.setComponentEnabledSetting`, как у
  `LxBoxIntentReceiver.setEnabled`; если индексатор всё равно показывает
  функции — (б) `AppFunctionManager.setAppFunctionEnabled` для каждой функции
  (в схеме — выключены по умолчанию). Требование одно: при выключенном
  тумблере `execute-app-function` не исполняет функцию.
- Тумблер входит в LX Backup и Debug API там же, где настройка автоматизации,
  если та туда входит; иначе — не добавлять.

### Сборка

- `app/android/app/build.gradle.kts`: `compileSdk = 37` (только модуль app;
  `targetSdk` не трогать), зависимости `appfunctions` и `appfunctions-compiler`
  версии `1.0.0-rc01`, плагин KSP версии, совместимой с Kotlin 2.3.21
  (в `settings.gradle.kts` рядом с `org.jetbrains.kotlin.android`).
- Манифест и `res/xml/app_metadata.xml` — по разделу Diagnosis.
- R8: убедиться, что релизная сборка не вырезает порождённый сервис и
  сериализуемый тип (в rc01 правила едут с библиотекой; если нет — добавить).
- `minSdk` остаётся 24: весь код за `@RequiresApi(36)`, обращения из общего
  кода — под проверкой `Build.VERSION.SDK_INT >= 36`.

### Документация

- `docs/AUTOMATION.md` — раздел «AI assistants (AppFunctions)»: что умеет,
  как включить, проверка через adb, оговорка про экспериментальный статус.
- `CHANGELOG.md` → Unreleased.
- Фича как чёрный ящик — в описание фичи автоматизации в `docs/spec/features/`
  (найти существующую по §047; новую папку не заводить, если есть куда дописать).

## Требования Google Play (раздел AppFunctions API, с 14.04.2027)

| Требование | Как выполнено |
|------------|---------------|
| Точное описание | KDoc описывает ровно действие функции; имена `startVpn` / `stopVpn` / `getVpnStatus` |
| Нет инструкций агенту в ответах | Ответ — одно поле с перечислимым значением; чужой текст (имена узлов) не возвращается |
| Не мешать другим приложениям и выбору агента | В описаниях нет упоминаний других приложений и приоритетов |
| Минимум входных данных | Параметров нет |
| Раздел «Безопасность данных» | Функции не собирают и не передают пользовательские данные; декларацию менять не требуется |

## Risks and edge cases

- `compileSdk 37` и KSP затрагивают релизную сборку, сборку F-Droid и
  воспроизводимость. Поэтому работа идёт на ветке `build/721-appfunctions`,
  в `develop` — после зелёной сборки CI (`build-fast`).
- AGP 9.1.0 может предупреждать о непроверенном `compileSdk 37` — допустимо,
  если сборка проходит; подавление — по сообщению Gradle.
- Библиотека в статусе rc; при выходе 1.0.0 — поднять версию.
- Холодный процесс: функция исполняется без Flutter. В коде функций нельзя
  обращаться к `VpnPlugin`/MethodChannel как к обязательной зависимости.
- Старт без согласия на VPN из фона невозможен — только ошибка агенту.
- Не покрыто: выбор сервера, диагностика, подписки — отдельные решения.

## Verification

1. CI `build-fast` на ветке `build/721-appfunctions` зелёный (Kotlin
   компилируется, APK собран).
2. JVM-тест чистой логики (отображение `VpnStatus` → строка, решение «можно
   ли стартовать») в `app/android/app/src/test`.
3. На эмуляторе Android 16, если сборка доступна локально:
   - тумблер выключен → `list-app-functions` не показывает включённых функций
     либо `execute-app-function` отказывает;
   - тумблер включён → `getVpnStatus` возвращает `stopped`; `startVpn` при
     выданном согласии поднимает туннель и возвращает `started`; `stopVpn`
     возвращает `stopped`;
   - согласие не выдано → `startVpn` возвращает ошибку с текстом из таблицы,
     приложение не открывается.
4. Сборка для Android < 16 запускается, строки тумблера нет.

## Unresolved / follow-up

- Заявка в программу раннего доступа Google (EAP) — делает владелец.
- Имя сервера в статусе, выбор сервера — после открытия доступа и решения
  владельца.
