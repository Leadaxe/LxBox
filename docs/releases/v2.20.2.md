# L×Box v2.20.2

An empty release — cut by mistake, changes nothing. The APK is functionally
identical to v2.20.1: no reason to install it, no harm if you do.

Пустой релиз — выпущен по ошибке и ничего не меняет. APK функционально
идентичен v2.20.1: ставить незачем, но и вреда нет.

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## What happened

While working towards byte-for-byte reproducibility for F-Droid, two native
libraries came out with different `.note.gnu.build-id` values on the two
sides. The fix looked obvious: pass `--build-id=sha1` so the id is derived
from the file contents instead of being assigned at random.

That flag was already in place. The NDK sets it unconditionally for every
CMake build (`build/cmake/flags.cmake`) and always has — `libdartjni.so` has
carried the same build id since v2.19.7. The hook added in this release
duplicated a default and changed nothing; it has been removed.

The differing ids therefore come from the input to the linker, not from the
algorithm. That work continues.

## What this means for you

Nothing. Same code, same behaviour as v2.20.1.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## Что произошло

В работе над побайтовой воспроизводимостью для F-Droid две нативные
библиотеки давали разный `.note.gnu.build-id` на двух сторонах. Решение
выглядело очевидным: передать `--build-id=sha1`, чтобы отпечаток считался от
содержимого файла, а не назначался случайно.

Этот флаг там уже стоял. NDK ставит его безусловно для любой CMake-сборки
(`build/cmake/flags.cmake`) и делал это всегда — `libdartjni.so` несёт один и
тот же build id начиная с v2.19.7. Хук, добавленный в этом релизе, дублировал
дефолт и ничего не менял; он снят.

Значит расхождение отпечатков идёт от входа линковки, а не от алгоритма.
Работа над этим продолжается.

## Что это значит для вас

Ничего. Тот же код, то же поведение, что в v2.20.1.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.20.2-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved.

---

Previous release / Предыдущий релиз: [v2.20.1](docs/releases/v2.20.1.md).
