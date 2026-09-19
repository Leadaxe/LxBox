/// Предупреждения узла — типизированные, агрегируемые, рендер по локали.
///
/// Плюсуются в `NodeSpec.warnings` (mutable list, §2.4 спеки 026) при
/// парсинге и при emit'е (fallback'ах типа XHTTP → httpupgrade). UI
/// (`subscription_detail_screen`) рендерит по severity через `message(l)`;
/// machine-поверхности (emitWarnings/AppLog) — `renderEn()` (ui_msg.dart).
library;

import '../services/contract/registry_warning.dart';
import '../services/l10n/get_local_text.dart';
import '../services/l10n/locale_controller.dart';

enum WarningSeverity { info, warning, error }

sealed class NodeWarning {
  const NodeWarning();

  /// §480 — предупреждение ПО КОДУ реестра.
  ///
  /// Движок маппера знает только код: записи секции называют `on_present`/
  /// `on_invalid` строкой, и выбирать подкласс ему нечем. Почти всегда ответ
  /// — [RegistryWarning] с текстом из `warnings.json`; исключения — коды, у
  /// которых СВОЙ подкласс с собственным текстом и собственным равенством,
  /// заведённый раньше реестра.
  ///
  /// Список исключений держится здесь, одним местом, и короток намеренно:
  /// каждый такой подкласс — это текст, живущий в коде вместо реестра, то
  /// есть долг. Новый код заводить сюда не нужно — он получит
  /// [RegistryWarning] и текст из реестра.
  ///
  /// Вторая половина `switch` — не исключения, а перекладывание: код
  /// получает [RegistryWarning], но с ИМЕНОВАННЫМ параметром, которого
  /// движку взять неоткуда (см. комментарии у веток).
  static NodeWarning byCode(
    String code, {
    required String path,
    required String value,
  }) =>
      switch (code) {
        // Тексты реестра ждут подстановку не под общим `{value}`, а под
        // ИМЕНЕМ, которое код объявил в `params`. Движок же знает про
        // предупреждение ровно две вещи — путь записи и значение, — потому
        // что больше ему знать и неоткуда: `on_present`/`on_invalid` несут
        // только код. Перекладывание здесь и делает из двух общих полей
        // именованный параметр реестра; таблица короткая ПО ПОСТРОЕНИЮ —
        // в неё попадает только код, чей текст зовёт своё имя.
        'ech_ignored' => RegistryWarning(
            code: code,
            path: path,
            value: value,
            // `query_name` — ИМЯ ПАРАМЕТРА ссылки (`ech`), а не его
            // значение: так решил лаунчер (контракт 1.1.15, ответ на сверку
            // §24.26 п.4), и запись `tls.blocks.uri.ech` объявляет ровно это.
            params: {'query_name': path},
          ),
        'ws_early_data_converted' => RegistryWarning(
            code: code,
            path: path,
            value: value,
            // Значение кода — то, ЧТО получилось из хвоста `?ed=N`
            // (`_convertedValue` движка), оно же `max_early_data` тела.
            params: {'max_early_data': value},
          ),
        'naive_extra_headers_invalid' => RegistryWarning(
            code: code,
            path: path,
            value: value,
            params: {'entry': value},
          ),
        // Два кода AWG сюда БОЛЬШЕ НЕ ПОПАДАЮТ (контракт 1.1.33). Их текст
        // держался в коде ровно потому, что реестровый умел подставить одно
        // лишь `{field}` и давал «field {field} removed» — человеку это не
        // говорило ничего. Теперь `warnings.json` называет и поле, и
        // написанное значение (`{path}`/`{value}`, оба подставляются всегда),
        // и объясняет последствие: ядро откатится на обычный заголовок
        // WireGuard, и если сервер ждёт AmneziaWG, рукопожатие может не
        // сойтись. Держать вторую копию этого текста незачем — она разошлась
        // бы с реестром молча.
        //
        // `naive_padding_ignored` сюда не попадает по той же причине: его
        // текст зовёт `{value}`, а тот подставляется всегда
        // (`text_params_implicit`).
        _ => RegistryWarning(code: code, path: path, value: value),
      };

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

// `transport_unsupported` — текст в реестре (`transports.json` → fallback
// транспорта). Класс снят (§485): код ставит движок, не парсер.

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

// `field_missing` — текст в реестре (санитайзер обязательных полей).
// `flow_deprecated` — текст в реестре (`protocols/vless.json` → `flow`).
// Классы сняты (§485).

// §115 / §472 шаг 9 — `VisionWithTransportWarning` снят: гашение
// `xtls-rprx-vision` при живом транспорте исполняет санитайзер по реестру
// (`protocols/vless.json` → `flow`, `conflicts`), код `vision_with_transport`
// приходит с путём и значением. Производителей в lib/ не осталось после
// переезда Xray-входа (шаг 8).

// `tls_insecure` — текст в реестре (`tls.json` → `insecure`, advisory).
// Класс снят (§485): severity `info` — данные контракта, не константа в коде.

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

/// §281 / ядро SPEC 083 — REALITY с uTLS-отпечатком без гибридного key share.
/// REALITY-сервер Xray ≥ v26.9.8 требует в ClientHello key_share
/// `X25519MLKEM768` перед X25519 и без него молча проксирует соединение на
/// камуфляжный сайт: нода мертва без ошибки.
///
/// §451 / ядро SPEC 086+087 — с libbox v1.14.1-lx.3 гибрид несут также
/// `firefox` (Firefox 148) и `safari` (Safari 26.3): под предупреждение
/// остаются только `edge`, `ios`, `android`, `360`, `qq` (см.
/// `kRealityHybridFingerprints`).
///
/// §444 — только предупреждение: отпечаток узла из подписки уходит в конфиг
/// как есть, приложение не переписывает выбор источника. Текст не обещает
/// `chrome`, а советует его.
final class RealityFingerprintWarning extends NodeWarning {
  final String value;
  const RealityFingerprintWarning(this.value);

  @override
  List<Object?> get props => [value];

  @override
  String messageWith(GetLocalText t) => t.s("REALITY with uTLS fingerprint \"%s\": Xray servers since v26.9.8 reject this ClientHello. If the connection fails, try \"chrome\".", value);

  /// §468 (контракт 1.1.2) — уровень берётся из реестра, а не из константы:
  /// владелец понизил код до `info`, и зашитая здесь копия разошлась бы с
  /// нормативным источником на первом же его изменении. Код узла и его
  /// severity — данные контракта (24.1.5), а не решение приложения.
  @override
  WarningSeverity get severity => registrySeverity('reality_fp_not_chrome');
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

// `ech_ignored` — текст в реестре (`warnings.json`), класса нет: параметр
// `ech` Xray-формы несёт ключ чужого клиента, снимается всегда (D-122).

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

// `ws_early_data_converted` — текст в реестре: хвост `?ed=N` разложен на
// `max_early_data` + `early_data_header_name`, путь в конфиг уехал не
// буквально. Ставится ровно на path-tail форму, не на плоские `ed=`/`eh=`
// (`transports.json` → `blocks.xray.ws.path`, `extract.into.ed.code`).

/// `reality_short_id_invalid` (info) — REALITY `sid` содержит не-hex символы,
/// нечётной длины или длиннее 16 hex-цифр. Ядро декодирует short_id как hex
/// в `[8]byte`: любое из этих условий — fatal ВСЕГО конфига на старте.
/// Значение отбрасывается целиком (пустой short_id для REALITY легален), а не
/// подгоняется: обрезка дала бы валидную форму с ЧУЖИМ идентификатором —
/// тихая порча (сервер сверяет sid побайтово).
///
// `reality_short_id_invalid` — текст в реестре (`tls.json` →
// `reality.short_id`). Класс снят (§485).

// `naive_padding_ignored` и `naive_extra_headers_invalid` — текст в реестре
// (`protocols/naive.json` → `mappers.uri.params.padding` / `extra-headers`).
// `padding` у naive sing-box-эквивалента не имеет; битая пара
// `extra-headers` пропускается, остальные живут, код ставится ОДИН раз на
// узел. Собственный `headers` у http/https-прокси под код не попадает.

/// §435 — запись секции узла отброшена при разборе документа
/// (`{ endpoints: [тело], sections: {…} }`): чужой `kind` или битая форма.
/// Остальные записи живут (NODE_SECTIONS.md §1). Кода контракта нет — UI.
final class SectionsRecordDroppedWarning extends NodeWarning {
  /// Путь и причина: `rules[1]: kind "preset" is not allowed in node sections`.
  final String detail;

  const SectionsRecordDroppedWarning(this.detail);

  @override
  List<Object?> get props => [detail];

  @override
  String messageWith(GetLocalText t) =>
      t.s("Node section record dropped: %s", detail);

  @override
  WarningSeverity get severity => WarningSeverity.info;
}

/// §435 — документ узла несёт и `sections`, и `dns`/`route` (NODE_SECTIONS.md
/// §7: оба вида в одном документе — ошибка). Парсер подписки берёт `sections`,
/// редактор узла такой документ не сохраняет. Кода контракта нет — UI.
final class SectionsConflictWarning extends NodeWarning {
  const SectionsConflictWarning();

  @override
  String messageWith(GetLocalText t) => t.s(
      "The document carries both \"sections\" and \"dns\"/\"route\": \"sections\" was taken, the rest was ignored.");

  @override
  WarningSeverity get severity => WarningSeverity.warning;
}

// §472 шаг 9 — `TuicCongestionInvalidWarning` снят: `congestion_control` вне
// {cubic, new_reno, bbr} судит санитайзер по реестру (`tuic.json`, enum +
// `on_invalid: drop`), код `tuic_congestion_invalid` приходит с путём и
// значением. Производителей в lib/ не осталось после шага 5.

// Контракт 1.1.33 — `AwgHeaderInvalidWarning` и `Awg3FieldInvalidWarning`
// сняты вместе с `ech_ignored` и соседями (§482): тексты обоих кодов
// переписаны в `warnings.json` с `{path}` и `{value}` и объясняют
// последствие — ядро откатится на обычный заголовок WireGuard, и если сервер
// ждёт AmneziaWG, рукопожатие может не сойтись. Прежняя запись реестра
// подставляла одно `{field}` и давала «field {field} removed», ради чего
// текст и жил в коде; теперь копия была бы вторым источником правды.
//
// Коды ставит `NodeWarning.byCode` (ветка по умолчанию) — `RegistryWarning` с
// путём поля и написанным значением, severity `warning` из реестра.

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

// §472 шаг 9 — `MasqueVhttpInvalidWarning` снят: `vhttp` вне {h3, h2, auto}
// приводит к h3 санитайзер по реестру (`protocols/masque.json`, enum +
// `on_invalid: coerce h3`), код `masque_vhttp_invalid` приходит с путём и
// значением. Производителей в lib/ не осталось после шага 7.

// §472 шаг 9 — `AnyTlsMinIdleInvalidWarning` снят: `min_idle_session` судит
// санитайзер по реестру (`protocols/anytls.json`, `min: 0` +
// `on_invalid: drop`), код `anytls_min_idle_invalid` приходит с путём и
// значением. Производителей в lib/ не осталось после шага 6.

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

/// §460 — предупреждение санитайзера реестра контракта.
///
/// Тексты кодов живут в `contract/registry/warnings.json` (24.1.5), а не в
/// словарях приложения: реестр нормативен для обеих сторон, и своя таблица
/// разошлась бы с ним на первом же пине ядра. Поэтому класс один на все коды
/// санитайзера — `unknown_key`, `type_invalid`, `field_conflict`,
/// `field_requires`, `tls_field_unsupported_naive`, `ss_method_legacy` и
/// прочие, — а различает их поле [code].
///
/// Здесь класс потому, что `NodeWarning` объявлена `sealed`: Dart 3
/// разрешает наследование только внутри её библиотеки. Логика рендера —
/// `services/contract/registry_warning.dart`.
final class RegistryWarning extends NodeWarning {
  const RegistryWarning({
    required this.code,
    this.path,
    this.value,
    this.params = const {},
    this.ownerTag = '',
  });

  /// Код из `registry/warnings.json` — он же код конформанса (CANON §6).
  final String code;

  /// Путь поля в теле узла (`tls.reality.key_share`); `null` у кодов уровня
  /// записи.
  final String? path;

  /// Значение, вызвавшее код; у `secret`-полей — `***` (24.1.4).
  final String? value;

  /// Прочие подстановки текста (`with`, `requires`, `winner`, `method`).
  final Map<String, String> params;

  /// §477 — тег записи, СНЯТОЙ ЦЕЛИКОМ (`on_invalid: drop_node`), для
  /// `dropped[].ref` контракта (corpus/README «Отбраковки», D-088). Пусто у
  /// обычного кода поля: он живёт на узле, и адресовать его нечем, кроме
  /// [path].
  ///
  /// Вне [props] намеренно: `props` — это ИДЕНТИЧНОСТЬ предупреждения, по ней
  /// идёт дедуп (§279). Тег же говорит не «что случилось», а «с какой
  /// записью», и включение его в идентичность развело бы на два сообщения
  /// один и тот же код об одном и том же поле у соседних узлов.
  final String ownerTag;

  @override
  List<Object?> get props =>
      [code, path, value, ...params.entries.map((e) => '${e.key}=${e.value}')];

  /// Строка узла — `title_<lang>` реестра. Язык: `ru` при русском UI, иначе
  /// `en` (`zh` падает в `en`, пока лаунчер не добавит третий набор).
  /// Пиненный английский [GetLocalText.en] (`renderEn`) всегда даёт `en` —
  /// иначе machine-поверхности зависели бы от языка UI.
  @override
  String messageWith(GetLocalText t) =>
      registryTitle(code, _langFor(t), path: path, value: value, params: params);

  /// Карточка узла — `text_<lang>` реестра. Пусто = кода в реестре нет.
  String detailWith(GetLocalText t) =>
      registryText(code, _langFor(t), path: path, value: value, params: params);

  /// [GetLocalText.en] — const-синглтон пиненного английского, поэтому
  /// отличить его от локализатора активной локали можно по идентичности:
  /// тега языка сам `t` не несёт.
  RegistryLang _langFor(GetLocalText t) => identical(t, GetLocalText.en)
      ? RegistryLang.en
      : registryLangForTag(LocaleController.I.effectiveTag);

  @override
  WarningSeverity get severity => registrySeverity(code);
}
