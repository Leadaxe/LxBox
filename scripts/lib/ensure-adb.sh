#!/usr/bin/env bash
# §219 — общий adb-path bootstrap. Раньше дублировался в install-apk.sh /
# ensure-wifi-adb.sh / lxbox-diag.sh / diag/post-crash-capture.sh (в последнем
# даже с явным комментом «то же что в lxbox-diag.sh»).
#
# ensure_adb_path: если adb не в PATH — добавляет ANDROID_SDK_ROOT/platform-tools
# и проверяет снова. Возвращает 0 если adb доступен, 1 иначе. Стратегию (fail vs
# degrade) решает вызывающий по коду возврата — тексты сообщений тоже у него.

ensure_adb_path() {
  command -v adb >/dev/null 2>&1 && return 0
  export PATH="${ANDROID_SDK_ROOT:-/usr/local/share/android-commandlinetools}/platform-tools:$PATH"
  command -v adb >/dev/null 2>&1
}
