# LxBox Icon — 3 Winners

После 30 концепций, 10 реализаций и критики от трёх персон (power-user / growth-маркетолог / product-manager) — финал.

## Единая бренд-палитра
- **Base**: slate-navy `#0F172A` → `#1E293B` (градиент фона)
- **Primary accent**: cyan `#22D3EE` (technical, proxy/routing)
- **Warm accent**: amber `#F59E0B` (human warmth, highlight)
- **Ink**: `#F8FAFC` (structural elements)

Зафиксирована по жёсткой рекомендации маркетолога: без общей палитры A/B-тесты сравнивают не иконки, а разные бренды.

---

## 🏆 Winner 1 — Routing Cross
**Архетип**: функциональный символ. `winners/W1_routing_cross.svg`

**Обоснование**: единственный концепт в топ-3 у всех трёх ревьюеров. Два перекрещивающихся вектора — это одновременно × из L×Box и метафора smart-routing (основная фича). Работает без буквенного костыля → легко масштабируется на desktop/iOS клиенты.

**Когда выбрать**: если главный сигнал — «умный роутинг, а не просто VPN».

**Скоры**: User 8.0 · Market 7.5 · PM 8.0 · **средний 7.8**

## 🏆 Winner 2 — L× Monogram
**Архетип**: буквенная марка. `winners/W2_Lx_monogram.svg`

**Обоснование**: стратегический топ PM-оценки (9.3) — единственный концепт, который без потерь масштабируется до 16×16 favicon, живёт в iOS 18 tinted mode и даёт прямой mapping «L×Box wordmark → icon». L стилизована как `box`-уголок (inside-corner bracket) — не просто буква, а намёк на контейнер. Amber × доминирует над белой L, что фиксирует бренд-тикер «**×**».

**Когда выбрать**: если приоритет — долгосрочный бренд-актив (favicon, README, website, iOS-ready).

**Скоры**: User 6.2 · Market 6.0 · PM **9.3** · средний 7.2

## 🏆 Winner 3 — Iso Cube + L-cord
**Архетип**: продуктовая метафора. `winners/W3_iso_cube.svg`

**Обоснование**: маркетолог выделил как warm-accent с max-CTR потенциалом. Изометрический куб — язык «продукт / tool» (Docker / Linear / Arc). Amber L-шнур — единственный тёплый акцент во всём VPN-ландшафте Play Store. Маленькая L выгравирована на верхней грани — subtle brand-detail. Композицию перецентрировал по фидбеку user-ревью, cord упрощён до одного 90°-загиба.

**Когда выбрать**: если продуктовое позиционирование — «power-tool / контейнер для трафика», а не «VPN-сервис».

**Скоры**: User 6.8 · Market 7.5 · PM 6.0 · средний 6.8

---

## Рекомендация

**Primary**: W2 L× Monogram (favicon, GitHub, website, wordmark).  
**App icon (Android)**: A/B тест W1 vs W3.  
- W1 — функциональная дифференциация от конкурентов.  
- W3 — эмоциональный warm-hit в результатах Play Store.

Каждый идёт с monochrome-вариантом (`*_mono.svg`) для tinted mode / favicon / CI badge.

## Следующие шаги для продакшна
1. Экспорт PNG: 1024 (store), 512, 192, 144, 96, 72, 48, 36 (Android adaptive foreground — 432×432 safe zone).
2. Android adaptive icon: foreground — winner без фона, background — solid `#0F172A`.
3. iOS 18 light/dark/tinted — tinted = mono-SVG.
4. `app/assets/icons/app_icon.png` заменить после выбора финала.
5. README badges, favicon 32/16, PWA manifest (если web-версия).

## Артефакты
- [CONCEPTS.md](CONCEPTS.md) — все 30 концепций
- [REVIEW.md](REVIEW.md) — три независимых ревью + синтез
- [index.html](index.html) — галерея всех 10 финалистов-до-синтеза
- [winners/index.html](winners/index.html) — 3 победителя в реальных размерах
- [winners/](winners/) — финальные SVG (color + mono)
