# L×Box v2.25.15-rc.1

**A release candidate on top of [v2.25.14](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.14).**

This is a pre-release on GitHub; in Google Play it goes to Open testing. It is
not offered to users of the stable release.

Default routing presets are on right after install, without opening the
Routing screen first. Core `v1.14.3-lx.18` and contract 1.1.119 are unchanged.

**Релиз-кандидат поверх [v2.25.14](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.14).**

На GitHub это pre-release, в Google Play сборка уходит в открытое
тестирование. Пользователям стабильного релиза она не предлагается.

Дефолтные пресеты маршрутизации включаются сразу после установки, без
открытия экрана Routing. Ядро `v1.14.3-lx.18` и контракт 1.1.119 без
изменений.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 🩹 Fixed

- **Default routing presets are on right after install ([task 644](docs/spec/tasks/644-default-presets-seed-before-routing.md)).**
  Presets the template enables by default (Russia-only services, BitTorrent,
  Tailscale networks, Unknown traffic, VoWiFi) reached the config only after
  the Routing screen was opened once. A node added and connected before that
  ran without them. They are now seeded at app start and before the config is
  built, once per install. A preset you removed does not come back.

## 📚 Documentation

- The template feature spec (024) is updated to contract 1.1.119.

## 🔧 Under the hood

- Core `v1.14.3-lx.18` and launcher contract 1.1.119, unchanged from v2.25.14.
- New test: default presets seeded on a clean install before the build.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 🩹 Исправлено

- **Дефолтные пресеты маршрутизации включаются сразу после установки ([задача 644](docs/spec/tasks/644-default-presets-seed-before-routing.md)).**
  Пресеты, включённые в шаблоне по умолчанию (Russia-only services,
  BitTorrent, Tailscale networks, Unknown traffic, VoWiFi), попадали в конфиг
  только после первого открытия экрана Routing. Узел, добавленный и
  подключённый до этого, шёл без них. Теперь они засеваются при старте
  приложения и перед сборкой конфига, один раз на установку. Удалённый
  пресет не возвращается.

## 📚 Документация

- Спека фичи шаблона (024) приведена к контракту 1.1.119.

## 🔧 Под капотом

- Ядро `v1.14.3-lx.18` и контракт лаунчера 1.1.119 — без изменений с v2.25.14.
- Новый тест: дефолтные пресеты засеваются на чистой установке до сборки.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.15-rc.1-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.14](docs/releases/v2.25.14.md).
