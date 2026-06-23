# L×Box v2.4.4

**Hotfix: пресет «Unknown traffic» ронял конфиг.** С включённым пресетом `block_unknown` (значение по умолчанию — Reject) при пересборке конфига вылетал fatal: `Config invalid: Rule "rules[N]" references missing outbound "reject"`. Ошибка всплывала на вкладке Servers и не давала запустить VPN, а плашка «Settings changed — rebuild config» горела не гасясь (битый конфиг не сохранялся → состояние всегда «грязное»). Подтверждено на устройстве.

**Quick links:**
[🐛 Fixed](#-fixed) ·
[🔬 Verified](#-verified) ·
[📲 Install](#-install) ·
[🇷🇺 На русском](#-кратко-на-русском)

---

## 🐛 Fixed

| # | Было | Стало |
|---|---|---|
| §162 | Пресет `block_unknown` со значением по умолчанию (`outbound: "@outbound"` + `default_value: "reject"`): если пресет просто включён и OutboundPicker не открывали, нормализация `reject → action` пропускалась (она жила только в ветке явного выбора). Литерал `outbound: "reject"` уезжал в `route.rules` → `reject` это `action`, а не outbound-tag → fatal на старте/пересборке. Ошибка на Servers + вечная плашка «settings changed» | **Безусловный backstop в `expandPreset`**: `outbound == "reject"` → `action: reject` независимо от того, override это или дефолт. Конфиг валиден, VPN стартует, плашка гаснет. Самолечит обновление без миграции (пресет хранит только `{presetId, varsValues}`, правило ребилдится из шаблона) |
| §161 (ч.2) | Стёртое required-поле (`tolerance` и т.п.) уходило в конфиг как `""` → ядро падало на decode так же, как от вне-диапазонного значения | **Пустое required → подстановка `default_value`** на трёх точках: UI сам чинит при загрузке экрана (и персистит), build-backstop при merge vars (ловит импорт бэкапа/legacy), блок сохранения пустого required + `errorText: "Required"`. optional-vars и `secret` исключены |
| UI | Плашка «Settings changed — tap to rebuild config» реагировала на тап только при попадании точно в текст/иконку — короткий текст в широком контейнере оставлял справа «мёртвую» зону | **`HitTestBehavior.opaque`** — тап ловится по всей площади плашки. Чинит и прочие кликабельные плашки (`restart`, `config_load_error`) |

## 🔬 Verified

- `flutter analyze` — **No issues found**.
- `flutter test` — **1247 passed**, включая регресс-тест §162 (`default_value=="reject"` в `@outbound`, пикер не трогали → `action:reject`, не `outbound:reject`); тест red без фикса, green с ним.
- **На устройстве** (OnePlus CPH2411, Android 15): на старой сборке подтверждён fatal в app-логах (`Rule "rules[3]" references missing outbound "reject"`) и вечная плашка «settings changed»; с фиксом — конфиг содержит `{"rule_set":"unknown-apps","action":"reject"}`, ошибка ушла.
- Ядро — **`v1.13.13-lx.15`** (без изменений; форк sing-box-lx, fetch с SHA256-verify).

## 📲 Install

```bash
adb install -r LxBox-v2.4.4-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

## 🇷🇺 Кратко на русском

- **Исправлен пресет «Unknown traffic» (§162).** Если включить пресет и не выбирать вручную, куда отправлять трафик (по умолчанию — Reject/блокировка), конфиг ломался: ошибка `references missing outbound "reject"` вылезала на вкладке Servers, VPN не запускался, а плашка «настройки изменились — пересоберите конфиг» горела постоянно. Теперь работает. Чинится само при обновлении, ничего вручную делать не нужно.
- **Пустое обязательное поле больше не роняет ядро (§161, ч.2).** Если стереть обязательное значение (например Tolerance), приложение подставит значение по умолчанию вместо пустоты, а пустым его сохранить не даст.
- **Плашка «пересобрать конфиг» теперь нажимается по всей ширине**, а не только по тексту.
- **Ядро — без изменений** (`v1.13.13-lx.15`).
