# §206 — `dns_final` default → `cloudflare_udp` + единая палитра плашек

## Часть A — `dns_final` default

## Проблема

Дефолт `dns_final` в шаблоне был `local_dns_resolver` (System DNS). Системный
резолвер раскрывает unmatched DNS-запросы ISP'у в обход VPN — выбран он был
исторически «на стабильность» (см. [§039][039], [§121][121]), не на приватность.

Юзер запросил энкриптед/туннелированный дефолт: `cloudflare_udp` (1.1.1.1:53,
detour `direct-out`), который и так включён по умолчанию и уже является
дефолтом для `dns_default_domain_resolver`.

## Изменения

1. **`app/assets/wizard_template.json`** — var `dns_final`
   `default_value`: `local_dns_resolver` → `cloudflare_udp`.

2. **`app/lib/screens/dns_settings_screen.dart`** — автосброс при исчезновении
   выбранного сервера из доступных тегов: fallback `dns_final`
   `local_dns_resolver` → `cloudflare_udp` (в соответствие новому template
   default; `cloudflare_udp` включён по умолчанию → всегда есть как таргет).

## Что НЕ меняется

- **Storage-миграция не нужна.** `dns_final` — template-var, хранит выбор юзера.
  Кто уже выбрал свой сервер — остаётся при нём. Новый дефолт применяется только
  к свежим/несохранённым конфигам.
- Исторические release-notes (`docs/releases/v1.6.0.md`, `v1.7.3.md`) и
  spec-таски §039/§121 фиксируют состояние на момент написания — не правим.

[039]: ./039-empty-template-dns-rules.md
[121]: ./121-preset-routing-king-dns-orphans.md

## Часть B — единая палитра плашек (dark/light)

### Проблема

Жёлтая плашка-предупреждение `LocalResolverWarningBanner` (показывается, когда
`dns_default_domain_resolver = local_dns_resolver`) была нечитаема в **тёмной
теме**: жёстко заданный фон `Colors.amber.shade100` (светлый) + текст из
`cs.onSurface` (в dark → почти белый) = белым по светло-жёлтому. Те же
хардкод-`Colors.amber.shade700` warning-иконки разбросаны по `resolver_picker`,
`stats_screen` — каждую пришлось бы чинить отдельно.

### Решение

Единый источник theme-aware цветов: **`app/lib/widgets/banner_palette.dart`**.

- `enum BannerSeverity { info, warning, error, success }`.
- `BannerColors bannerColors(context, severity)` — `{background, border,
  foreground, action}` для плашки с фоном. `info`/`error` из `ColorScheme`
  (`*Container`/`on*Container`). `warning`/`success` — **явные light/dark
  amber/green пресеты** (тема приложения — `ColorScheme.fromSeed`, где
  `tertiary` НЕ гарантированно жёлтый; warning должен читаться как «жёлтое»).
- `Color bannerIconColor(context, severity)` — для одиночной ⚠-иконки на
  surface-фоне (без плашки).

**Light/dark пресеты живут только здесь** — меняем тут, меняется во всех плашках.

### Переведено на единый источник

| Файл | Было | Стало |
|---|---|---|
| `local_resolver_warning_banner.dart` | хардкод `Colors.amber.*` + `cs.onSurface` | `bannerColors(.warning)` |
| `resolver_picker.dart` | `Colors.amber.shade700` иконка | `bannerIconColor(.warning)` |
| `stats_screen.dart` | `Colors.amber.shade700` иконка (bypass-warn) | `bannerIconColor(.warning)` |

### Не трогалось

- `screens/home/widgets/app_banner.dart` — у home свой `BannerPalette` поверх
  `ColorScheme.*Container`; уже theme-aware и не сломан. Не сливали, чтобы не
  менять вид рабочих home-плашек. (Если решим унифицировать полностью —
  отдельный проход.)
- Точки-маркеры «фильтр активен» (`filter_panel`, `nodes_header`,
  `profiler_filter_sheet`) — это не плашки/предупреждения, а индикаторы; оставлены.
