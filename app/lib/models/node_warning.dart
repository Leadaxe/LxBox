/// Предупреждения узла — типизированные, агрегируемые, рендер по локали.
///
/// Плюсуются в `NodeSpec.warnings` (mutable list, §2.4 спеки 026) при
/// парсинге и при emit'е (fallback'ах типа XHTTP → httpupgrade). UI
/// (`subscription_detail_screen`) рендерит по severity через `message(l)`;
/// machine-поверхности (emitWarnings/AppLog) — `renderEn()` (ui_msg.dart).
library;

import '../services/l10n/get_local_text.dart';
import '../services/l10n/locale_controller.dart';

enum WarningSeverity { info, warning, error }

sealed class NodeWarning {
  const NodeWarning();

  /// §285 — тело рендера подкласса. [t] — локализатор: активная локаль для
  /// [message], пиненный английский [GetLocalText.en] для [renderEn].
  /// Публичный — переиспользуется композицией из ui_msg.dart (пофайловая
  /// приватность Dart). Интерполяции (scheme/transport/field) — wire-иды,
  /// не переводятся.
  String messageWith(GetLocalText t);

  /// §285 — рендер в момент показа (активная локаль через global getLocalText).
  String message() => messageWith(getLocalText);

  /// Machine-рендер (emitWarnings/AppLog) — пиненный английский, независимо
  /// от активной локали.
  String renderEn() => messageWith(GetLocalText.en);

  WarningSeverity get severity;

  /// Поля данных подкласса для равенства/hashCode. Dedup — по runtimeType +
  /// данным, НЕ по отрендеренной строке (§279: строка locale-зависима,
  /// равенство по ней ломало бы dedup при смене языка).
  List<Object?> get props => const [];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NodeWarning &&
          runtimeType == other.runtimeType &&
          _propsEqual(props, other.props));

  @override
  int get hashCode => Object.hashAll([runtimeType, ...props]);

  @override
  String toString() => '$runtimeType(${props.join(', ')})';
}

bool _propsEqual(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class UnsupportedTransportWarning extends NodeWarning {
  final String name;
  final String fallback;
  const UnsupportedTransportWarning(this.name, this.fallback);

  @override
  List<Object?> get props => [name, fallback];

  @override
  String messageWith(GetLocalText t) =>
      t.s("Transport \"%1\$s\" is not supported by sing-box; using \"%2\$s\" fallback (node may fail to connect).", name, fallback);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

final class UnsupportedProtocolWarning extends NodeWarning {
  final String scheme;
  const UnsupportedProtocolWarning(this.scheme);

  @override
  List<Object?> get props => [scheme];

  @override
  String messageWith(GetLocalText t) => t.s("Protocol \"%s\" is not supported.", scheme);

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

final class MissingFieldWarning extends NodeWarning {
  final String field;
  const MissingFieldWarning(this.field);

  @override
  List<Object?> get props => [field];

  @override
  String messageWith(GetLocalText t) => t.s("Required field \"%s\" is missing.", field);

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

final class DeprecatedFlowWarning extends NodeWarning {
  final String flow;
  const DeprecatedFlowWarning(this.flow);

  @override
  List<Object?> get props => [flow];

  @override
  String messageWith(GetLocalText t) => t.s("Flow \"%s\" is deprecated.", flow);

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// §115 — `xtls-rprx-vision` валиден только на голом TLS; с любым
/// транспортом (ws/grpc/httpupgrade/xhttp) несовместим — ядро такую
/// комбинацию не поднимет. Парсер гасит flow, warning сообщает почему.
final class VisionWithTransportWarning extends NodeWarning {
  final String transport;
  const VisionWithTransportWarning(this.transport);

  @override
  List<Object?> get props => [transport];

  @override
  String messageWith(GetLocalText t) => t.s("Flow \"xtls-rprx-vision\" is incompatible with \"%s\" transport — flow dropped.", transport);

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

final class InsecureTlsWarning extends NodeWarning {
  const InsecureTlsWarning();

  @override
  String messageWith(GetLocalText t) => t.s("TLS certificate verification is disabled.");

  /// Info, не warning — это часто **намеренный** выбор провайдера (REALITY,
  /// IP-литералы, self-signed). Не должен крадовать XHTTP-fallback и прочие
  /// honestly-warning'и. UI красит info серым.
  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// libbox без `with_naive_outbound` — выставляется defensively после первой
/// runtime-ошибки старта sing-box на naive-узле. Точная upstream-строка:
/// `naive outbound is not included in this build, rebuild with -tags
/// with_naive_outbound`.
final class NaiveBuildTagWarning extends NodeWarning {
  const NaiveBuildTagWarning();

  @override
  String messageWith(GetLocalText t) => t.s("NaïveProxy is not included in this libbox build (rebuild with -tags with_naive_outbound).");

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

/// §281 — uTLS fingerprint вне словаря ядра заменён на chrome. Ядро матчит
/// fingerprint строго (`uTLSClientHelloID`, case-sensitive) — неизвестное
/// значение fatal для ВСЕГО конфига при старте. Известные xray-псевдонимы
/// (hellochrome_120 и т.п.) канонизируются молча — warning только на
/// полностью неопознанный мусор.
final class UnknownFingerprintWarning extends NodeWarning {
  final String value;
  const UnknownFingerprintWarning(this.value);

  @override
  List<Object?> get props => [value];

  @override
  String messageWith(GetLocalText t) => t.s("Unknown uTLS fingerprint \"%s\" replaced with \"chrome\" (would otherwise break the whole config).", value);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// §217 — причина сброса XHTTP-параметра (§279: enum вместо free-text —
/// текст рендерится в [XhttpParamResetWarning.message], не хранится).
enum XhttpResetReason {
  /// Значение вне допустимого enum-множества ядра (placement/method).
  invalidEnumValue,

  /// `uplink_data_placement` вне множества body/auto/header/cookie.
  invalidPlacementValue,

  /// header/cookie placement валиден только в packet-up режиме.
  placementRequiresPacketUp,

  /// `uplink_http_method: GET` валиден только в packet-up режиме (meta.go:105).
  getRequiresPacketUp,
}

/// §217 — XHTTP-параметр сброшен на дефолт, потому что его значение ядро
/// приняло бы только в другом режиме (или значение вне допустимого множества).
/// Без сброса одна такая нода роняет ВЕСЬ конфиг fatal при старте
/// (transport/v2rayxhttp/meta.go normalizeMeta). Нода остаётся рабочей.
final class XhttpParamResetWarning extends NodeWarning {
  final String field;
  final XhttpResetReason reason;

  /// Отвергнутое значение — только для invalid*-вариантов, иначе ''.
  final String value;

  const XhttpParamResetWarning(this.field, this.reason, {this.value = ''});

  @override
  List<Object?> get props => [field, reason, value];

  @override
  String messageWith(GetLocalText t) {
    final why = switch (reason) {
      XhttpResetReason.invalidEnumValue =>
        t.s("value \"%1\$s\" is not a valid %2\$s", value, field),
      XhttpResetReason.invalidPlacementValue =>
        t.s("value \"%s\" is not valid", value),
      XhttpResetReason.placementRequiresPacketUp =>
        t.s("header/cookie placement requires packet-up mode"),
      XhttpResetReason.getRequiresPacketUp => t.s("GET requires packet-up mode"),
    };
    return t.s("XHTTP \"%1\$s\" reset to default — %2\$s (would otherwise break the whole config).", field, why);
  }

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// §416 — XHTTP-узел пришёл с `uplink_data_placement: header`, но без `mode`.
/// Ядро принимает такой placement только в режиме `packet-up`
/// (`transport/v2rayxhttp/meta.go normalizeMeta`): без режима оно берёт
/// дефолт `auto` и роняет ВЕСЬ конфиг fatal при старте —
/// «uplink_data_placement can be header only in packet-up mode». Одна такая
/// нода в подписке не даёт подняться VPN вовсе.
///
/// Режим дописывается, а не placement снимается: `header` осмыслен ровно в
/// packet-up, так что источник фактически его и подразумевал — а снятие
/// placement'а собрало бы узел не так, как ждёт сервер. Явно заданный
/// НЕ-packet-up режим при этом не переписывается: там конфликт разбирает
/// [XhttpResetReason.placementRequiresPacketUp] (§169 — отброс, не подгонка).
final class XhttpModeForcedPacketUpWarning extends NodeWarning {
  const XhttpModeForcedPacketUpWarning();

  @override
  String messageWith(GetLocalText t) => t.s(
      "XHTTP mode was set to \"packet-up\": the link asks for header uplink data placement, which the core accepts only in that mode (the config would otherwise fail to load).");

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// §320 — `ech` из подписки проигнорирован. Xray-форма `ech=<name>+<resolver>`
/// не несёт ключа, а лишь имя для DNS-запроса; подписки кладут туда публичные
/// ECH-пробники (`ip.gs`, `encryptedsni.com`), чьи ключи не принадлежат серверу
/// узла — включённый ECH ломает рукопожатие. Проверить пригодность до
/// подключения нельзя, fallback в ядре отсутствует, поэтому параметр не
/// применяется. Info: узел от этого рабочий, теряется только маскировка SNI.
final class EchIgnoredWarning extends NodeWarning {
  /// Имя из левой части `ech` (до `+`), как его написал провайдер.
  final String queryName;

  const EchIgnoredWarning(this.queryName);

  @override
  List<Object?> get props => [queryName];

  @override
  String messageWith(GetLocalText t) => t.s(
      "ECH is not applied: \"%s\" from the link points to a public ECH probe, not to this server — enabling it would break the TLS handshake.",
      queryName);

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// §358 — тип hysteria2-обфускации вне словаря ядра (`salamander`, `gecko`)
/// отброшен. Оставить его нельзя: ядро отказывается сериализовать неизвестный
/// тип («unknown obfs type») и не собирает ВЕСЬ конфиг, а не одну ноду.
/// Узел подключится без обфускации — если сервер её требует, трафика не будет.
final class UnknownObfsWarning extends NodeWarning {
  /// Значение, как его написал провайдер.
  final String value;

  const UnknownObfsWarning(this.value);

  @override
  List<Object?> get props => [value];

  @override
  String messageWith(GetLocalText t) => t.s(
      "Unknown obfuscation type \"%s\" was dropped (the core supports salamander and gecko only, and would otherwise break the whole config). The node connects without obfuscation.",
      value);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// §358 — обфускация задана без пароля. Ядро требует непустой пароль для
/// любого типа («missing obfs password») и роняет весь конфиг, поэтому
/// обфускация снимается целиком.
final class MissingObfsPasswordWarning extends NodeWarning {
  /// Тип, который был указан в ссылке.
  final String type;

  const MissingObfsPasswordWarning(this.type);

  @override
  List<Object?> get props => [type];

  @override
  String messageWith(GetLocalText t) => t.s(
      "Obfuscation \"%s\" has no password, so it was dropped (the core requires one and would otherwise break the whole config). The node connects without obfuscation.",
      type);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

// ════════════════════════════════════════════════════════════════════════════
// §368 — импорт sing-box JSON
// ════════════════════════════════════════════════════════════════════════════

/// §368 §4 P3 — `detour`-кольцо в импортируемом конфиге разорвано.
///
/// Расхождение с §254 намеренное: там судят конфиг ПОЛЬЗОВАТЕЛЯ (виновника надо
/// показать, чтобы он развязал), здесь кольцо приехало из чужого файла — узлов
/// ещё нет, развязывать нечего. Рвём замыкающее ребро, узел остаётся рабочим
/// без цепочки.
final class DetourCycleBrokenWarning extends NodeWarning {
  /// Тег, на который вело замыкающее ребро.
  final String target;

  const DetourCycleBrokenWarning(this.target);

  @override
  List<Object?> get props => [target];

  @override
  String messageWith(GetLocalText t) => t.s(
      "Chain to \"%s\" would loop back on itself, so it was dropped. The node connects directly.",
      target);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// §368 §4 P4 — `detour` указывает на тег, которого в конфиге нет.
/// Узел не теряем (§169: отброс негодной части, не целого).
final class DetourTargetMissingWarning extends NodeWarning {
  final String target;

  const DetourTargetMissingWarning(this.target);

  @override
  List<Object?> get props => [target];

  @override
  String messageWith(GetLocalText t) => t.s(
      "Chain target \"%s\" was not found in the config. The node connects directly.",
      target);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// §368 §4 P5 — `detour` на группу (`urltest`/`selector`). Типово выразимо, но
/// `getEntries` развернёт группу в detour-список, где её членов нет.
final class DetourToGroupWarning extends NodeWarning {
  final String target;

  const DetourToGroupWarning(this.target);

  @override
  List<Object?> get props => [target];

  @override
  String messageWith(GetLocalText t) => t.s(
      "Chain target \"%s\" is a group, which cannot be used as a chain hop. The node connects directly.",
      target);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// §368 §4 P2 — цепочка длиннее лимита обрезана. Реальные конфиги — 2–3 звена;
/// лимит защищает от рекурсии по данным провайдера.
final class DetourChainTooDeepWarning extends NodeWarning {
  final int limit;

  const DetourChainTooDeepWarning(this.limit);

  @override
  List<Object?> get props => [limit];

  @override
  String messageWith(GetLocalText t) => t.s(
      "Chain is longer than %d hops and was truncated.", limit);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// §404 / контракт D-085 — у Xray-узла указан `sockopt.dialerProxy`, но
/// звено непригодно: цели нет в элементе, она не конвертируется в узел, это
/// группа, либо цепочка зациклена/глубже лимита.
///
/// Владелец в таком случае ОТБРАКОВЫВАЕТСЯ ЦЕЛИКОМ — узла с прямым путём не
/// создаётся. Отличие от `DetourTargetMissingWarning` (sing-box-ветка, §368)
/// принципиальное: там `detour` — необязательное украшение маршрута, а здесь
/// провайдер явно завернул дозвон в релей. Подменить его прямым выходом
/// значит молча вывести трафик наружу мимо того звена, ради которого узел и
/// прислали.
///
/// [label] — имя узла, который выпал (то, что пользователь видит в списке);
/// [target] — тег недостижимой цели; [ownerTag] — СОБСТВЕННЫЙ тег
/// отбракованного outbound'а из конфига провайдера.
///
/// Тег и label — разные вещи, и обе нужны. Label приходит из `remarks`
/// ЭЛЕМЕНТА и на многоузловом элементе одинаков у всех его узлов; тег
/// называет конкретный outbound. Контракт (corpus/README «Отбраковки»,
/// D-088) требует в `dropped[].ref` именно тег: по нему вторая сторона
/// опознаёт отвергнутую запись, а человеческое имя для машинной сверки не
/// годится. В тексте пользователю при этом остаётся label — тег провайдера
/// (`proxy`) ему ничего не говорит.
final class DialerProxyUnusableWarning extends NodeWarning {
  final String label;
  final String target;

  /// Тег отвергнутого outbound'а — `dropped[].ref` контракта. Пусто, если
  /// провайдер тега не дал: тогда опознать запись можно только по label.
  final String ownerTag;

  const DialerProxyUnusableWarning(this.label, this.target,
      {this.ownerTag = ''});

  @override
  List<Object?> get props => [label, target, ownerTag];

  @override
  String messageWith(GetLocalText t) => t.s(
      "Node \"%1\$s\" was dropped: its relay \"%2\$s\" is missing, unusable or loops. Connecting directly would have bypassed the relay.",
      label,
      target);

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

/// §368 §5.1 — `type: selector` (ручной выбор) импортирован как автовыбор:
/// своего типа узла у нас нет, а терять собранный руками состав хуже, чем
/// сменить режим отбора.
final class SelectorAsAutoWarning extends NodeWarning {
  const SelectorAsAutoWarning();

  @override
  String messageWith(GetLocalText t) => t.s(
      "\"selector\" was imported as an auto-select group: the fastest member is picked by latency tests instead of manually.");

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// §368 §5.3 — член группы не доехал: тег не дал узла (служебный/битый
/// outbound) либо это вложенная группа, а группа членом пула быть не может.
final class GroupMemberMissingWarning extends NodeWarning {
  /// Сколько членов выпало.
  final int count;

  const GroupMemberMissingWarning(this.count);

  @override
  List<Object?> get props => [count];

  @override
  String messageWith(GetLocalText t) =>
      t.plural("%d group members could not be imported and were left out.", count);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

// ════════════════════════════════════════════════════════════════════════════
// SPEC 103 — деградации, которые лаунчер уже помечает кодом, а Dart раньше
// глушил в лог. Восемь классов ниже закрывают разрыв «Go ставит код, Dart
// молчит»: параметр подписки отбрасывается ОДИНАКОВО, но пользователь мобилы
// об этом не узнавал. Коды — contract/registry/warnings.json, семантика
// (когда ставится, что в params) — зеркало Go-эталона, проверяется общим
// корпусом contract/corpus/uri/**.
// ════════════════════════════════════════════════════════════════════════════

/// `ws_early_data_converted` (info) — Xray-хвост `?ed=N` в WebSocket-пути
/// разложен на sing-box-поля `max_early_data` + `early_data_header_name`.
/// Путь в конфиг попадает НЕ буквально: без конверсии ядро отдало бы хвост
/// серверу как часть пути и тот ответил бы 404 (issue #96), причём
/// `sing-box check` при этом проходит. Узел рабочий — отсюда info.
///
/// Ставится ровно на path-tail форму (`path=/x?ed=N`), НЕ на плоские
/// `ed=`/`eh=` в query: те Go вообще не читает как early data-конверсию.
/// Go-эталон: `noteWSEarlyDataConverted` (node_parser_core.go).
final class WsEarlyDataConvertedWarning extends NodeWarning {
  /// Значение `ed` из хвоста пути — оно уехало в `max_early_data`.
  final int maxEarlyData;

  const WsEarlyDataConvertedWarning(this.maxEarlyData);

  @override
  List<Object?> get props => [maxEarlyData];

  @override
  String messageWith(GetLocalText t) => t.s(
      "WebSocket early data \"?ed=%d\" was moved out of the path into a separate field, as the core requires. The node works; the path in the config is not literally the one from the link.",
      maxEarlyData);

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// `reality_short_id_invalid` (info) — REALITY `sid` содержит не-hex символы,
/// нечётной длины или длиннее 16 hex-цифр. Ядро декодирует short_id как hex
/// в `[8]byte`: любое из этих условий — fatal ВСЕГО конфига на старте.
/// Значение отбрасывается целиком (пустой short_id для REALITY легален), а не
/// подгоняется: обрезка дала бы валидную форму с ЧУЖИМ идентификатором —
/// тихая порча (сервер сверяет sid побайтово).
///
/// Go-эталон: `realityShortIDWouldDegrade` (parse_warnings.go:72) —
/// непустое сырое значение, чья нормализация не совпала с `lower(trim(raw))`.
final class RealityShortIdInvalidWarning extends NodeWarning {
  /// Значение, как его написал провайдер.
  final String value;

  const RealityShortIdInvalidWarning(this.value);

  @override
  List<Object?> get props => [value];

  @override
  String messageWith(GetLocalText t) => t.s(
      "REALITY short id \"%s\" is not valid hex, so it was dropped (keeping it would break the whole config). The node connects without a short id.",
      value);

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// `naive_padding_ignored` (info) — URI-параметр `padding` у naive не имеет
/// sing-box-эквивалента; игнорируется, узел живёт.
final class NaivePaddingIgnoredWarning extends NodeWarning {
  /// Значение параметра, как оно пришло в ссылке.
  final String value;

  const NaivePaddingIgnoredWarning(this.value);

  @override
  List<Object?> get props => [value];

  @override
  String messageWith(GetLocalText t) => t.s(
      "NaïveProxy parameter \"padding=%s\" has no equivalent in the core and was ignored. The node still works.",
      value);

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// `tuic_congestion_invalid` (warning) — TUIC `congestion_control` вне
/// {cubic, new_reno, bbr}. Поле снимается (ядро подставит свой дефолт),
/// узел живёт. Go-эталон: node_parser_tuic.go:73.
final class TuicCongestionInvalidWarning extends NodeWarning {
  final String value;

  const TuicCongestionInvalidWarning(this.value);

  @override
  List<Object?> get props => [value];

  @override
  String messageWith(GetLocalText t) => t.s(
      "TUIC congestion control \"%s\" is not one of cubic, new_reno, bbr — the setting was dropped and the core default applies.",
      value);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// `awg_header_invalid` (warning) — AmneziaWG magic-header (h1–h4) не uint32
/// и не диапазон `lo-hi`. Поле снимается, ядро возьмёт WireGuard-дефолт —
/// а с ним handshake не совпадёт с сервером (тихо сломанный узел: рукопожатие
/// уходит, ответа нет). Отсюда warning, а не info.
///
/// Только h1–h4: битые jc/jmin/jmax/s1–s4 Go пропускает молча (debug-лог).
/// Go-эталон: `applyAWGFields` (node_parser_wireguard.go:400).
final class AwgHeaderInvalidWarning extends NodeWarning {
  /// Имя поля — `h1`…`h4`.
  final String field;

  /// Значение, как его написал провайдер.
  final String value;

  const AwgHeaderInvalidWarning(this.field, this.value);

  @override
  List<Object?> get props => [field, value];

  @override
  String messageWith(GetLocalText t) => t.s(
      "AmneziaWG header \"%1\$s=%2\$s\" is neither a number nor a \"low-high\" range, so it was dropped. The core falls back to the plain WireGuard header and the handshake may not match the server.",
      field,
      value);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// §421 `awg3_field_invalid` (warning) — AWG 3.x тайминг/паддинг
/// (content_padding_addition, rekey_*, reject_after_time, keepalive_timeout,
/// max_handshake_attempts) с мусором или перевёрнутым диапазоном `N>M`,
/// либо булево (random_trailers/disable_cookies) не on/off. Поле снято, узел
/// живёт: тайминги клиентские, ядро работает на своих дефолтах. Границы НЕ
/// свопаются (в отличие от h1–h4). Go-эталон: `applyAWG3Fields` (awg3.go).
final class Awg3FieldInvalidWarning extends NodeWarning {
  /// URI/.conf-имя параметра (`contentpaddingaddition`, `randomtrailers`…).
  final String field;

  /// Значение, как его написал провайдер.
  final String value;

  const Awg3FieldInvalidWarning(this.field, this.value);

  @override
  List<Object?> get props => [field, value];

  @override
  String messageWith(GetLocalText t) => t.s(
      "AmneziaWG 3 field \"%1\$s=%2\$s\" is neither a number, an ordered \"low-high\" range nor on/off, so it was dropped. The core uses its default for it.",
      field,
      value);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// §421 `awg3_header_key_invalid` (error) — `header_protection_key` не
/// base64, не 32 байта или все нули. УЗЕЛ выброшен на разборе, а не помечен:
/// без верного ключа хендшейк невозможен, а ядро отвергает такой конфиг
/// целиком — один узел лишил бы пользователя VPN. Класс — источник текста
/// причины для лога отбраковки. Go-эталон: `validateAWG3` (awg3.go).
final class Awg3HeaderKeyInvalidWarning extends NodeWarning {
  const Awg3HeaderKeyInvalidWarning();

  @override
  String messageWith(GetLocalText t) => t.s(
      "AmneziaWG 3 header protection key is not a 32-byte base64 key, so the node was skipped: the handshake cannot succeed and the core would reject the whole config.");

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

/// §421 `awg3_padding_too_short` (error) — при заданном
/// `header_protection_key` один из s1–s4 меньше 12 (или не задан). УЗЕЛ
/// выброшен: nonce шифра заголовка берётся из первых 12 байт паддинга, ядро
/// отвергает такую пару на проверке конфига (docs-lx §2.9/§2.10).
final class Awg3PaddingTooShortWarning extends NodeWarning {
  /// `s1`…`s4`.
  final String field;

  /// Минимум (12).
  final int min;

  const Awg3PaddingTooShortWarning(this.field, this.min);

  @override
  List<Object?> get props => [field, min];

  @override
  String messageWith(GetLocalText t) => t.s(
      "AmneziaWG 3 padding \"%1\$s\" is below %2\$d, the minimum required by the header protection key, so the node was skipped: the core would reject the whole config.",
      field,
      min);

  @override
  WarningSeverity get severity => WarningSeverity.error;
}

/// §421 `awg3_random_trailers_wide_headers` (info) — `random_trailers`
/// вместе с ШИРОКИМ диапазоном h1–h4 (ширина ≥ 65536). Ничего не снимается:
/// это свойство протокола — референсный приёмник сервера принимает
/// data-датаграммы за кандидатов хендшейка с вероятностью ширина/2³² и
/// отбрасывает их на MAC, страдает uplink. Go-эталон:
/// `awg3RandomTrailersWithWideHeaders` (awg3.go).
final class Awg3RandomTrailersWideHeadersWarning extends NodeWarning {
  const Awg3RandomTrailersWideHeadersWarning();

  @override
  String messageWith(GetLocalText t) => t.s(
      "AmneziaWG 3 random trailers are combined with a wide magic-header range (65536 or more); the server may mistake some upload packets for handshakes and drop them.");

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// `masque_vhttp_invalid` (warning) — MASQUE `vhttp` вне {h3, h2, auto};
/// принудительно h3. `auto` принят контрактом 0.11.1 (ядро >= lx.27).
/// Go-эталон: node_parser_masque.go:100.
final class MasqueVhttpInvalidWarning extends NodeWarning {
  final String value;

  const MasqueVhttpInvalidWarning(this.value);

  @override
  List<Object?> get props => [value];

  @override
  String messageWith(GetLocalText t) => t.s(
      "MASQUE HTTP version \"%s\" is not h3, h2 or auto — h3 was used instead.",
      value);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// `anytls_min_idle_invalid` (warning) — anytls `min_idle_session` не
/// неотрицательное целое; поле снимается, узел живёт.
/// Go-эталон: node_parser_anytls.go:40.
final class AnyTlsMinIdleInvalidWarning extends NodeWarning {
  final String value;

  const AnyTlsMinIdleInvalidWarning(this.value);

  @override
  List<Object?> get props => [value];

  @override
  String messageWith(GetLocalText t) => t.s(
      "AnyTLS \"min_idle_session=%s\" is not a non-negative whole number — the setting was dropped and the core default applies.",
      value);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

/// `packet_encoding_unknown` (warning) — `packet_encoding` вне
/// {xudp, packetaddr}. Поле снимается: неизвестное значение даёт не ошибку
/// конфига, а панику ядра (`unknown packet encoding` → краш libbox целиком).
///
/// Пустое значение и `none` — семантический эквивалент «поля нет» (так их
/// пишут xray-подписки), деградацией не считаются и кода не получают.
/// Go-эталон: node_parser_core.go:622, singbox_sanitize.go:260.
final class PacketEncodingUnknownWarning extends NodeWarning {
  final String value;

  const PacketEncodingUnknownWarning(this.value);

  @override
  List<Object?> get props => [value];

  @override
  String messageWith(GetLocalText t) => t.s(
      "Packet encoding \"%s\" is not one the core knows (xudp, packetaddr), so it was dropped — keeping it would crash the core.",
      value);

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}
