# Сборка BoxVPN

## Flutter-приложение

Каталог **`app/`** — проект BoxVPN. Зависимости подтягиваются через `flutter pub get` (в т.ч. **`flutter_singbox_vpn`**, libbox на Android с [JitPack](https://jitpack.io) — репозиторий указан в `android/build.gradle.kts`).

```bash
cd app
flutter pub get
flutter run   # устройство или эмулятор Android
```

## CI (GitHub Actions)

Workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) на **push/PR в `main`** выполняет `analyze`, `test`, `flutter build apk` (**debug** и **release**) и выкладывает артефакты **`android-apk-debug`** и **`android-apk-release`** (вкладка **Actions** → последний run → **Artifacts**). Release в шаблоне подписан debug-keystore (как в `app/android/app/build.gradle.kts`), для магазина нужна своя подпись.

## Версии

- В workflow зафиксированы **Flutter 3.41.6** и **JDK 17**; при обновлении — править `ci.yml` и этот файл.
