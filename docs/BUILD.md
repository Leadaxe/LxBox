# Сборка BoxVPN

## Flutter-приложение

Каталог **`app/`** должен содержать проект Flutter. Если его ещё нет:

```bash
cd /path/to/BoxVPN
flutter create --org com.leadaxe --project-name boxvpn_app app
```

Дальше:

```bash
cd app
flutter pub get
flutter run   # устройство или эмулятор Android
```

## CI (GitHub Actions)

Workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) на **push/PR в `main`** выполняет `analyze`, `test`, `flutter build apk` (**debug** и **release**) и выкладывает артефакты **`android-apk-debug`** и **`android-apk-release`** (вкладка **Actions** → последний run → **Artifacts**). Release в шаблоне подписан debug-keystore (как в `app/android/app/build.gradle.kts`), для магазина нужна своя подпись.

## Версии

- В workflow зафиксированы **Flutter 3.41.6** и **JDK 17**; при обновлении — править `ci.yml` и этот файл.
