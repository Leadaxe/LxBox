import '../services/l10n/locale_controller.dart';
import 'version_info.dart';

/// §362 — единственный источник ссылок проекта. До этого адреса лежали
/// копиями по экранам (About, Automation-tab, update_checker) и в текстах
/// support-ленты — смена адреса требовала обхода всех мест.
///
/// Здесь же — подстановка `@плейсхолдеров` в remote-контенте (support.json):
/// автор пишет `"url": "@guideLink"` вместо адреса, приложение подставляет
/// актуальное значение — в том числе локале-зависимое (гайд ru/en).
class ProjectLinks {
  ProjectLinks._();

  static const repo = 'https://github.com/Leadaxe/LxBox';
  static const latestRelease =
      'https://github.com/Leadaxe/LxBox/releases/latest';
  static const core = 'https://github.com/Leadaxe/sing-box-lx';
  static const launcher = 'https://github.com/Leadaxe/singbox-launcher';
  static const singboxUpstream = 'https://github.com/SagerNet/sing-box';
  static const telegram = 'https://t.me/singbox_launcher/4317';
  static const donate = 'https://t.me/singbox_launcher/340/3621';
  static const issues = 'https://github.com/Leadaxe/LxBox/issues';
  static const forum4pda = 'https://4pda.to/forum/index.php?showtopic=1122662';
  static const automationDoc =
      'https://github.com/Leadaxe/LxBox/blob/main/docs/AUTOMATION.md';

  /// §361 — руководство пользователя. Пара RU/EN держится синхронной
  /// CI-проверкой парности (tool/docs/parity_check.dart). Ветка `main`: в APK
  /// попадает релизный код, а релиз — это merge в main, который принесёт туда
  /// и оба файла гайда. Незнакомый тег → английская версия, а не 404.
  static const guideEn =
      'https://github.com/Leadaxe/LxBox/blob/main/docs/USER_GUIDE.md';
  static const guideRu =
      'https://github.com/Leadaxe/LxBox/blob/main/docs/USER_GUIDE_RU.md';

  static String guideFor(String tag) => tag == 'ru' ? guideRu : guideEn;

  static String releaseTag(String tag) =>
      'https://github.com/Leadaxe/LxBox/releases/tag/$tag';

  /// Плейсхолдеры remote-контента. Значения резолвятся В МОМЕНТ показа:
  /// `@guideLink` зависит от текущей локали, `@appVersion` — от версии APK.
  static Map<String, String> placeholders() => {
        '@selfLink': latestRelease,
        '@repoLink': repo,
        '@coreLink': core,
        '@launcherLink': launcher,
        '@tgLink': telegram,
        '@donateLink': donate,
        '@issuesLink': issues,
        '@pdaLink': forum4pda,
        '@guideLink': guideFor(LocaleController.I.effectiveTag),
        '@appVersion': VersionInfo.I.version,
      };

  /// Подстановка `@плейсхолдеров` в произвольной строке (url/label/message).
  /// Неизвестный `@токен` остаётся текстом как есть — опечатка автора не
  /// ломает сообщение и видна глазом. Длинные имена подставляются первыми,
  /// чтобы префикс не съедал более длинный ключ.
  static String expand(String raw) {
    if (!raw.contains('@')) return raw;
    final map = placeholders();
    final keys = map.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    var out = raw;
    for (final k in keys) {
      if (out.contains(k)) out = out.replaceAll(k, map[k]!);
    }
    return out;
  }
}
