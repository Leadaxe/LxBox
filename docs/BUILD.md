# Сборка BoxVPN

## Flutter-приложение

Каталог **`app/`** — проект BoxVPN. Зависимости подтягиваются через `flutter pub get` (в т.ч. **`flutter_singbox_vpn`**, libbox на Android с [JitPack](https://jitpack.io) — репозиторий указан в `android/build.gradle.kts`). Импорт конфига по кнопке **Read**: **JSON** или **JSON5/JSONC** (комментарии `//`, `/* */` — парсер `json5`), затем в ядро уходит канонический JSON; источник — буфер или системный диалог выбора файла.

```bash
cd app
flutter pub get
flutter run   # устройство или эмулятор Android
```

## Минимальный конфиг для проверки на телефоне

Файл **[`docs/examples/minimal_local_test.json`](examples/minimal_local_test.json)** — валидный sing-box JSON: только **tun** + **direct/block** в селекторе (без платного/чужого прокси), **Clash API** на `127.0.0.1:9090` без секрета. Подходит, чтобы убедиться, что **Read → Start** поднимает туннель и в UI появляются группа **proxy** и узлы **direct** / **block**. Интернет при этом идёт как обычно через direct (не «обход»).

## CI (GitHub Actions)

Workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) на **push/PR в `main`** выполняет `analyze`, `test`, `flutter build apk` (**debug** и **release**) и выкладывает артефакты **`android-apk-debug`** и **`android-apk-release`** (вкладка **Actions** → последний run → **Artifacts**). Release в шаблоне подписан debug-keystore (как в `app/android/app/build.gradle.kts`), для магазина нужна своя подпись.

## Версии

- В workflow зафиксированы **Flutter 3.41.6** и **JDK 17**; при обновлении — править `ci.yml` и этот файл.
