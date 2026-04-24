# 034 — App icon (W1 routing-cross)

| Поле | Значение |
|------|----------|
| Статус | Active (shipped в v1.5.0; финальный дизайн в v1.5.x) |
| Дата | 2026-04-24 |
| Source | [`docs/design/icon/W1_pack/`](../../../design/icon/W1_pack/) |

---

## Цель

Заменить generic Flutter-иконку на кастомный визуал, отражающий природу продукта (VPN-клиент с маршрутизацией по правилам). Старая Flutter-иконка в сторе / на домашнем экране не отличалась от тысяч демо-аппов — пользователь не мог найти L×Box в поиске по иконке, визуальная идентичность ноль.

## Выбранный вариант — W1 "routing cross"

Победитель из 30 концептов → 10 SVG-реализаций → ревью тремя персонами (power-user / growth-marketer / product manager) → итеративная полировка. Консенсус-топ (только W1 был в топ-3 у всех трёх ревьюеров). Итоговая композиция смешивает W1 с элементами W2 (letter-mark L): L-рамка + × из пересекающихся стрелок + 3 узла-хаба.

### Визуальные компоненты финальной иконки

- **Warm-orange gradient** `#FB923C → #EA580C` — выделение в VPN-категории, где ~90% иконок синие/зелёные.
- **Ivory L-frame** (вертикаль слева + половина горизонтали) — буква **L** из L×Box, физически обрамляет левую/нижнюю сторону.
- **Navy ↗ arrow (BL→TR)** с 60°-наконечником — главный routing-поток.
- **Ivory ↘ diagonal (TL→BR)** с 90°-наконечником — встречный/direct-поток; вместе со стрелкой образует **×** (routing-cross и знак × из L×Box).
- **3 navy-узла с ivory-центрами** (TL, BL, central hub) — хаб + узлы-подписки.
- **Navy dashed inner trace** — пунктир внутри вертикали L-рамки, добавляет текстуру на больших размерах.

### Отклонённые альтернативы

- **W2 Lx-monogram** — слишком generic letter-mark, путается с v2rayNG/NekoRay.
- **W3 iso-cube + L-cord** — красиво в 512, в 48 превращается в пиксель-клубок.
- **07 flow-diode (red→green)** — классический VPN-штамп «грязь/чистота», срабатывает trust-минус у privacy-аудитории.
- **09 terminal L× (CRT-green)** — сужает аудиторию до хакер-ниши, эстетика устаревает к 2027.

Полная история ревью — см. git log `docs/design/icon/` (до удаления черновиков).

## 4-tier система (responsive reduction)

Иконка адаптируется к размеру рендера — чем меньше, тем меньше деталей. Все 4 варианта представлены как `<symbol>` в [`showcase.html`](../../../design/icon/W1_pack/showcase.html):

| Tier | Размеры | Отличия от hero |
|------|---------|-----------------|
| **hero** | ≥ 48 px | Всё: L-рамка + пунктир + × + 3 узла |
| **clean** | 32 / 36 px | — пунктир |
| **mid** | 24 px | — пунктир, — L-рамка (остаются только × + 3 узла) |
| **micro** | ≤ 16 px | только × (2 стрелки с наконечниками) + центральный хаб |

В продакшн (Flutter launcher icons) попадает только hero — платформенные mipmap'ы все ≥ 48 px. Tier'ы clean/mid/micro заготовлены для будущего favicon-pack / иных контекстов (tab-иконки, маленькие UI-элементы).

## Файлы

**Источники** (SVG + HTML):

```
docs/design/icon/W1_pack/
├── W1_master.svg        — canonical 512×512 SVG; все 4 tier'а описаны как варианты в showcase
└── showcase.html        — preview всех 4 tier'ов + home-screen mockup + маски
```

**Экспортированные asset'ы** (PNG/ICO, попадают в build):

| Платформа | Путь | Размеры |
|-----------|------|---------|
| Source | `app/assets/icons/app_icon.png` | 1024×1024 (rendered из W1_master.svg) |
| Android mipmap | `app/android/app/src/main/res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` | 48–192 |
| iOS AppIcon | `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*` | 20–1024 |
| macOS AppIcon | `app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png` | 16–1024 |
| Web | `app/web/icons/Icon-*.png`, `app/web/favicon.png` | 16–512 |
| Windows | `app/windows/runner/resources/app_icon.ico` | multi-size |

Смежный проект `singbox-launcher` (macOS/Windows tray-launcher) использует тот же дизайн: `assets/app.png`, `assets/app.icns`, `assets/app.ico`. Иконки состояний tray (`on.ico` / `off.ico`) — отдельный дизайн, не трогаем.

## Обновление иконки в будущем

1. Отредактировать [`W1_master.svg`](../../../design/icon/W1_pack/W1_master.svg).
2. Рендер 1024×1024 PNG:
   ```bash
   qlmanage -t -s 1024 -o /tmp docs/design/icon/W1_pack/W1_master.svg
   cp /tmp/W1_master.svg.png app/assets/icons/app_icon.png
   ```
3. Регенерация платформенных иконок:
   ```bash
   cd app && dart run flutter_launcher_icons
   ```
4. (Опционально) обновить symbol'ы в `showcase.html` если дизайн менялся структурно — там 4 inline-копии (hero/clean/mid/micro), каждая обновляется отдельно.
5. (Опционально) продублировать в singbox-launcher:
   ```bash
   cp /tmp/W1_master.svg.png ~/projects/singbox-launcher/assets/app.png
   cd ~/projects/singbox-launcher/assets && ./convert-to-icns.sh app.png app.icns
   python3 -c "from PIL import Image; Image.open('app.png').save('app.ico', format='ICO', sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])"
   ```
6. Коммит — все платформы вместе.

## Acceptance

- [x] Launcher-иконка на Android — W1 routing-cross
- [x] iOS AppIcon — W1 на всех размерах
- [x] macOS AppIcon — W1
- [x] Web favicon — W1
- [x] Windows app icon — W1
- [x] About-screen (in-app) — `assets/icons/app_icon.png`
- [x] singbox-launcher — тот же дизайн на macOS (.icns) + Windows (.ico)
- [x] showcase.html — preview всех 4 tier'ов
