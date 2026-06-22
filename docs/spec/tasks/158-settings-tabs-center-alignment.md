# 158 — App Settings: центрировать вкладки + edge-fade

| Поле | Значение |
|------|----------|
| Статус | **Done** (2026-06-22) — `TabAlignment.center` + статический двусторонний edge-fade (`ShaderMask`); `flutter analyze` чисто; on-device подтверждено на CE8XX48PCI79U4XG (Android 13), UX принят |
| Дата | 2026-06-22 |
| Тип | UX-фикс (скрытый горизонтальный скролл TabBar) |
| Повод | Вкладка «Automation» уезжает за правый край экрана, нет намёка что табы скроллятся |
| Связано | §047 (Automation добавила 4-ю вкладку), §156 (UI English-only) |

---

## TL;DR

В `App Settings` четыре вкладки в `TabBar(isScrollable: true)` —
**General / Subscriptions / Diagnostics / Automation**. На узких экранах
суммарная ширина подписей превышает ширину экрана, последняя вкладка
(«Automation») оказывается за правым краем, и нет визуального намёка, что бар
скроллится.

Финальное решение — **две части**:

1. **`tabAlignment: TabAlignment.center`** — набор поджимается к центру, край
   обрезанной вкладки («Automation») попадает в кадр частично → уже виден
   намёк, что справа есть ещё.
2. **Статический двусторонний edge-fade** (`_FadingTabBar` → `ShaderMask`
   `BlendMode.dstIn`) — последние ~32px у каждого края затухают в прозрачность,
   так что **обрезанная подпись уходит в размытие**, а не обрывается резкой
   линией. Это и есть «мягкий» намёк на скролл.

---

## Почему статический fade, а не отслеживание скролла

В первых попытках fade был **динамическим** — зависел от позиции скролла через
`ScrollNotification` / `ScrollMetricsNotification`. Это оказалось хрупким
(не рисовался на первом кадре без жеста) и незаметным на устройстве. Также
пробовался **peek-намёк** (авто-скролл вправо-назад при открытии) — на
устройстве не сработал.

Статический edge-fade проще и надёжнее: не ждёт scroll-метрик, гарантированно
рисуется на первом кадре, симметрично затухает оба края. В паре с
центрированием обрезанный текст всегда упирается в зону затухания → выглядит
как «уходит за край», а не «обрублен».

Trade-off: fade затемняет крайние 32px всегда, даже если там нет обрезанного
текста. При 4 широких центрированных табах край почти всегда занят — приемлемо.

---

## Files

| File | Change |
|---|---|
| `app/lib/screens/app_settings_screen.dart` | в `AppBar.bottom` заменить `TabBar` на `_FadingTabBar(tabs: …)`; добавить `_FadingTabBar` (`StatelessWidget` + `PreferredSizeWidget`): `ShaderMask` с симметричным edge-fade поверх `TabBar(isScrollable: true, tabAlignment: TabAlignment.center)` |

Изменение чисто-клиентское: ни storage, ни native, ни method-channel.

---

## Verification

- [x] `flutter analyze lib/screens/app_settings_screen.dart` — No issues found
- [x] release-сборка arm64 (`build-local-apk.sh`) — `✓ Built
      app-arm64-v8a-release.apk (29.3MB)`
- [x] on-device (CE8XX48PCI79U4XG, Android 13): App Settings — вкладки
      центрированы, обрезанная «Automation» у правого края уходит в размытие
      (не резкий обрыв); тап/свайп по табам работают; UX принят юзером
