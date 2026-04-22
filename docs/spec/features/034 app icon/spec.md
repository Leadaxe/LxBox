# 034 — App icon (W1 routing-cross)

| Поле | Значение |
|------|----------|
| Статус | Active (shipped в v1.4.2) |
| Дата | 2026-04-22 |
| Source | [`docs/design/icon/W1_pack/`](../../../design/icon/W1_pack/) |

---

## Цель

Заменить generic Flutter-иконку на кастомный визуал, отражающий природу продукта (VPN-клиент с маршрутизацией по правилам). Старая Flutter-иконка в сторе / на домашнем экране не отличалась от тысяч демо-аппов — пользователь не мог найти L×Box в поиске по иконке, визуальная идентичность ноль.

## Выбранный вариант — W1 "routing cross"

Вариант **W1** (из 10 проработанных концептов + 3 финалистов). Концепт — пересечение двух путей под прямым углом, формирующее стилизованную букву «L» с горизонтальным штрихом. Визуальные ассоциации:

- **Routing / split** — два пути расходятся: метафора маршрутизации (direct / via proxy).
- **L в L×Box** — монограмма в скрытой форме.
- **Минимализм** — читаемо даже в 48×48 (launcher size).

Альтернативы (W2 Lx-monogram, W3 iso-cube) — отклонены:
- **W2** — читается как "Lx" но визуально тонкий, в sq-кропе launcher'а теряется.
- **W3** — красиво в 512, в 48 превращается в серый пиксель-клубок.

## Файлы

**Источники** (SVG, живут в репо):

```
docs/design/icon/W1_pack/
├── W1_master.svg               — reference 1024×1024
├── W1_adaptive_foreground.svg  — Android adaptive icon foreground
├── W1_adaptive_background.svg  — Android adaptive icon background
├── W1_favicon.svg              — web / browser tab
├── W1_mono.svg                 — monochrome (Android 13+ themed icons)
└── index.html                  — showcase / comparison page
```

**Экспортированные asset'ы** (PNG, попадают в build):

| Платформа | Путь | Размеры |
|-----------|------|---------|
| Android mipmap | `app/android/app/src/main/res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` | 48–192 |
| iOS AppIcon | `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*` | 20–1024 |
| macOS AppIcon | `app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png` | 16–1024 |
| Web | `app/web/icons/Icon-*.png`, `app/web/favicon.png` | 16–512 |
| Windows | `app/windows/runner/resources/app_icon.ico` | multi-size |
| Flutter asset | `app/assets/icons/app_icon.png` | 1024 (high-DPI fallback) |

## Обновление иконки в будущем

1. Отредактировать SVG в `docs/design/icon/W1_pack/` (обычно `W1_master.svg`).
2. Переэкспортировать PNG'ы через `flutter_launcher_icons` или вручную из SVG.
3. Сверить все платформы через `index.html` showcase в PR.
4. Коммит — один раз, все платформы вместе.

**Не менять** adaptive foreground/background без обновления обоих — Android 8+ комбинирует их.

## Acceptance

- [x] Launcher-иконка на Android — W1 routing-cross (adaptive, маскируется под системные паттерны)
- [x] Themed mono-версия на Android 13+
- [x] iOS AppIcon — W1 на всех размерах
- [x] macOS AppIcon — W1
- [x] Web favicon — W1
- [x] Windows app icon — W1
