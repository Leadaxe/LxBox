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

После появления `app/pubspec.yaml` workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) на **push/PR в `main`** выполняет `analyze`, `test`, `flutter build apk --debug` и выкладывает **артефакт** `android-apk-debug` (вкладка **Actions** → последний run → **Artifacts**).

Пока каталога `app/` нет, job **flutter** в CI **пропускается** (условие `hashFiles('app/pubspec.yaml')`).

## Версии

- В workflow зафиксированы **Flutter 3.24.5** и **JDK 17**; при обновлении — править `ci.yml` и этот файл.
