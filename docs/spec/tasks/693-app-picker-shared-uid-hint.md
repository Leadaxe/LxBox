# 693 — UID приложения в пикере и подсказка об общем UID

| Поле | Значение |
|------|----------|
| Статус | Done (на устройстве не проверено) |
| Дата начала | 2026-10-29 |
| Источник | issue [#180](https://github.com/Leadaxe/LxBox/issues/180) (@usgrnk): на Samsung правило «block com.samsung.android.fmm» заблокировало всю группу UID 1000 — проверка обновлений системы не прошла, в Stats заблокированным значился Key Chain |
| Связанные | §053 (секция APPS редактора правила), §107/§109 (Tunnel apps, AppInfoCache), §412 (тап по строке пикера не меняет выбор) |

## Проблема

Android раздаёт одному UID несколько пакетов (`android:sharedUserId`; на Samsung
под UID 1000 «system» живут Find My Mobile, Software update, Key Chain и
десятки других). Ядро определяет владельца соединения по UID, поэтому
`package_name` в правиле на деле матчит весь UID: правило на один пакет
действует на всю группу, а в Stats соединение подписывается тем именем,
которое ядро выбрало для UID. Исключение приложений в VpnService
(Routing → Tunnel apps) тоже работает по UID.

Пользователь этого не видит: в пикере у строки только имя и пакет.

## Решение (слово владельца)

Только подсказка в UI. Семантика правил и Tunnel apps не меняется. Остальные
пакеты группы **не** выбираются автоматически (автор issue просит о том же:
иначе импорт списка на другом устройстве, где группа другая, даст сюрприз).

1. Native `getInstalledApps` и `getAppInfo` отдают `uid`
   (`ApplicationInfo.uid`). `AppInfo.uid` — `int?` (старый ответ без поля
   → `null`, подсказки нет).
2. `AppInfoCache.uidPeers(pkg)` — другие установленные пакеты с тем же UID,
   по полному списку `loadAllApps` (системные считаются, даже если в пикере
   скрыты). Пока полный список не загружен — пусто.
3. Пикер приложений (`AppPickerScreen`: Tunnel apps, APPS правила, URL Check):
   - подзаголовок строки — `com.pkg · UID 10234`;
   - если UID общий — вторая строка подзаголовка с иконкой группы:
     `Shared with 37 other apps — they are routed together`; тап по ней
     открывает диалог `UID 1000` со списком этих приложений (имя + пакет),
     только чтение, кнопка `Close`. Галочки при этом не меняются.
4. Tunnel apps, список выбранных: тот же подзаголовок и та же строка-подсказка
   (вкладка один раз дёргает `loadAllApps`, если список не пуст).
5. Секция APPS редактора правила показывает только счётчик — не меняется.

Макет строки:

```
[icon] Find My Mobile                              [x]
       com.samsung.android.fmm · UID 1000
       👥 Shared with 37 other apps — they are routed together
```

## Файлы

- `app/android/.../vpn/VpnPlugin.kt` — `uid` в двух ответах.
- `app/lib/models/app_info.dart` — поле `uid`.
- `app/lib/services/app_info_cache.dart` — `uidPeers`, `uid` сохраняется при
  дотягивании иконки.
- `app/lib/widgets/app_uid_subtitle.dart` — подзаголовок + диалог (общий для
  пикера и Tunnel apps).
- `app/lib/screens/app_picker_screen.dart`, `app/lib/screens/tun_apps_tab.dart`.
- `app/assets/l10n/{ru,zh}/ui.json` — новые строки.
- Тест: `app/test/screens/app_picker_shared_uid_test.dart`.

## Критерии

- Строка пикера показывает UID; у пакета с уникальным UID подсказки нет.
- У пакета с общим UID — подсказка с числом остальных пакетов; диалог
  перечисляет их; выбор не меняется ни от тапа по подсказке, ни от выбора
  пакета группы.
- Ответ native без `uid` — без UID и без подсказки, без падений.

## Проверка

- `test/screens/app_picker_shared_uid_test.dart` — 3/3: UID в подзаголовке,
  подсказка «Shared with 2 other apps» у пакетов группы (скрытый системный
  пакет считается), у уникального UID подсказки нет; диалог перечисляет
  группу, галочки не меняются; ответ без `uid` — ни UID, ни подсказки.
- `test/screens/app_picker_row_tap_test.dart` (§412) — зелёный.
- Эмулятор и телефон не гоняли: AVD на машине не запущен; на Samsung UID
  1000 проверит только владелец/автор issue.
