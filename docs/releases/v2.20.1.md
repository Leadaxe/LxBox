# L×Box v2.20.1

A patch release. The QR scanner added in v2.20.0 now uses a free decoder
instead of Google's proprietary one — same feature, nothing to relearn, but
the app can finally be built for F-Droid. A routing rule no longer jumps to
another position when you open it and close it without editing anything. The
bundled VPN core is updated to a build that fixes a crash on tunnel start.

Патч-релиз. QR-сканер из v2.20.0 переведён на свободный декодер вместо
проприетарного гугловского — функция та же, переучиваться нечему, но
приложение теперь можно собрать для F-Droid. Правило маршрутизации больше не
прыгает на другую позицию, если открыть его и закрыть, ничего не меняя.
Встроенное VPN-ядро обновлено до сборки, где исправлено падение при старте
туннеля.

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 🔄 Changed — the QR scanner runs on a free decoder

The scanner shipped in v2.20.0 recognised codes through ML Kit, a
closed-source Google component. It worked, but it made the app impossible to
publish on F-Droid: the catalogue requires that everything in the build is
free software and that the APK can be reproduced byte for byte from source.
Prebuilt binary models cannot satisfy either condition.

The decoder is now ZXing-C++, used through `flutter_zxing` — the same engine
that 38 other apps in the F-Droid catalogue already build with.

For you nothing changes: the same "Scan QR code" entry, the same camera
screen, the same confirmation dialog before anything is imported. Recognition
quality is comparable, and decoding actually runs a bit faster because it
happens in native code rather than in a Dart isolate.

One side effect worth knowing: the scanner is 4 MB smaller. The proprietary
component carried a 4.95 MB library plus three machine-learning models; the
free one is a single 1.81 MB library.

The first build of it felt worse than the old scanner — it searched inside a
small part of the frame and did not always catch the code straight away. That
was down to the widget's defaults rather than the decoder: the search area
covered only a quarter of the frame, and the thorough decoding pass was off.
The scanner now searches almost the whole frame, takes the slower and more
careful pass, and retries roughly two to three times a second instead of once.

There is also a small dot next to the hint at the bottom. It blinks on every
decoding attempt, so you can tell the scanner is still working — there is no
shutter button to press, and without it a scanner that is simply thinking
looks identical to one that has frozen.

## 🐛 Fixed — a routing rule jumped position after being opened

Opening a routing rule and closing it without touching anything could move
the rule to a different place in the list, and the editor claimed it had
unsaved changes when it did not.

The cause was in how the editor took a snapshot of the rule: it rebuilt the
rule without its position number, in all four kinds of rule. Comparing that
snapshot against the stored rule always showed a difference, so the form
considered itself dirty; saving then wrote the rule back without its
position, and the list re-sorted it elsewhere.

## 🔧 Core — sing-box-lx 1.14.0-lx.20-rc.6

The bundled core is updated from `rc.5` to `rc.6`. In `rc.5` the tunnel could
die while starting — sometimes on the first attempt, sometimes after several,
so a restart often appeared to fix it.

The cause was in how `rc.5` updated its WireGuard component: it had fallen
fourteen commits behind, and only three were taken. The eleven skipped ones
included timing-race fixes and a rework of internal locking. `rc.6` takes the
component whole and re-applies our own changes on top — the AmneziaWG
obfuscation, transport padding and socket self-healing.

Everything `rc.5` brought is still present: two months of upstream fixes,
OpenVPN and OpenConnect, the updated network stack.

## ✅ Tests

`flutter analyze` clean across the project, 2947 tests passing, all four
localisation checkers at zero findings in strict mode.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 🔄 Изменено — QR-сканер работает на свободном декодере

Сканер из v2.20.0 распознавал коды через ML Kit — закрытый компонент Google.
Он работал, но делал приложение непубликуемым в F-Droid: каталог требует,
чтобы всё в сборке было свободным и чтобы APK побитово воспроизводился из
исходников. Предсобранные бинарные модели не дают ни того, ни другого.

Теперь декодер — ZXing-C++ через `flutter_zxing`, тот же движок, с которым в
каталоге F-Droid уже собираются 38 других приложений.

Для вас не меняется ничего: тот же пункт «Scan QR code», тот же экран
камеры, то же подтверждение перед импортом. Качество распознавания
сопоставимо, а декодирование стало чуть быстрее — оно выполняется нативным
кодом, а не в Dart-изоляте.

Побочный эффект, о котором стоит знать: сканер стал легче на 4 МБ.
Проприетарный компонент тянул библиотеку на 4.95 МБ плюс три
модели машинного обучения; свободный — одна библиотека на 1.81 МБ.

Первая сборка ощущалась хуже прежнего сканера: искала в маленьком куске
кадра и не всегда сразу ловила код. Дело было в дефолтах виджета, а не в
декодере — область поиска покрывала лишь четверть кадра, а тщательный проход
распознавания был выключен. Теперь сканер ищет почти по всему кадру, делает
более медленный и внимательный проход и повторяет попытки два-три раза в
секунду вместо одного.

Рядом с подсказкой внизу появилась точка. Она моргает на каждой попытке
распознавания, чтобы было видно, что сканер работает: кнопки съёмки нет, а
без такого признака думающий сканер выглядит точно так же, как зависший.

## 🐛 Исправлено — правило маршрутизации прыгало после открытия

Если открыть правило маршрутизации и закрыть, ничего не тронув, оно могло
переехать на другое место в списке, а редактор при этом считал, что есть
несохранённые изменения, хотя их не было.

Причина — в том, как редактор снимал слепок правила: он пересобирал правило
без номера позиции, причём во всех четырёх видах правил. Сравнение такого
слепка с сохранённым всегда показывало расхождение, поэтому форма считала
себя «грязной»; сохранение записывало правило без позиции, и список
пересортировывал его в другое место.

## 🔧 Ядро — sing-box-lx 1.14.0-lx.20-rc.6

Встроенное ядро обновлено с `rc.5` до `rc.6`. В `rc.5` туннель мог падать при
старте — иногда с первой попытки, иногда через несколько, поэтому перезапуск
часто выглядел как решение проблемы.

Причина была в том, как `rc.5` обновлял свой WireGuard-компонент: тот отстал
на четырнадцать коммитов, а взято было только три. Среди одиннадцати
пропущенных — исправления гонок по таймингам и переработка внутренних
блокировок. В `rc.6` компонент взят целиком, а наши собственные изменения
наложены поверх — обфускация AmneziaWG, transport padding и самовосстановление
сокетов.

Всё, что принёс `rc.5`, на месте: два месяца исправлений upstream, OpenVPN и
OpenConnect, обновлённый сетевой стек.

## ✅ Тесты

`flutter analyze` чист по всему проекту, 2947 тестов проходят, все четыре
проверки локализации дают ноль замечаний в строгом режиме.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.20.1-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved.

---

Previous release / Предыдущий релиз: [v2.20.0](docs/releases/v2.20.0.md).
