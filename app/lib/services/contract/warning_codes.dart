/// §460 W2a — соответствие рукописного класса [NodeWarning] коду контракта.
///
/// Раньше таблица жила только в конформанс-раннере
/// (`test/contract/contract_test.dart`). Волна W2a добавила второго
/// потребителя — дедуп предупреждений реестра при разборе
/// (`parse_warnings.dart`): узел, которому парсер уже выдал рукописное
/// предупреждение, не обязан получать второе о том же от санитайзера.
/// Две копии таблицы разошлись бы на первом же новом классе, поэтому
/// таблица одна и живёт в lib.
///
/// Источник правды самого соответствия — `contract/registry/warnings.json`
/// (поле `dart`); синхронность сверяет `registry_sync_test`.
library;

import '../../models/node_warning.dart';

/// Код контракта по типу рукописного класса; класса нет в таблице —
/// у кода нет соответствия в реестре (в корпусе такие не встречаются).
const kWarningCodes = <Type, String>{
  UnsupportedProtocolWarning: 'protocol_unsupported',
  NaiveBuildTagWarning: 'naive_unavailable',
  UnknownFingerprintWarning: 'utls_fp_unknown',
  // D-119 (заменил D-104) — REALITY с явным отпечатком не из chrome-семейства
  // (SPEC 083 ядра); отпечаток не подменяется, только код на узле.
  RealityFingerprintWarning: 'reality_fp_not_chrome',
  XhttpParamResetWarning: 'xhttp_param_reset',
  // §416 — header-placement без режима: дописан mode: packet-up.
  XhttpModeForcedPacketUpWarning: 'xhttp_mode_forced_packet_up',
  UnknownObfsWarning: 'obfs_unknown',
  MissingObfsPasswordWarning: 'obfs_password_missing',
  DetourCycleBrokenWarning: 'detour_cycle_broken',
  DetourTargetMissingWarning: 'detour_target_missing',
  DetourToGroupWarning: 'detour_to_group',
  DetourChainTooDeepWarning: 'detour_chain_too_deep',
  GroupMemberMissingWarning: 'group_member_missing',
  // §421 — AWG 3.x (SPEC 123): error-коды — причина drop, в результат разбора узла
  // не попадают (узел выброшен), но класс ↔ код зеркалятся для полноты.
  // `awg_header_invalid` и `awg3_field_invalid` здесь БОЛЬШЕ НЕТ: классы
  // сняты (контракт 1.1.33), коды приходят `RegistryWarning` и несут свой
  // код полем.
  Awg3HeaderKeyInvalidWarning: 'awg3_header_key_invalid',
  Awg3PaddingTooShortWarning: 'awg3_padding_too_short',
  Awg3RandomTrailersWideHeadersWarning: 'awg3_random_trailers_wide_headers',
  PacketEncodingUnknownWarning: 'packet_encoding_unknown',
  // §404 / D-085 — недостижимый `dialerProxy` роняет владельца целиком;
  // причина уезжает в `dropped[]` результата разбора (corpus/README, D-088).
  DialerProxyUnusableWarning: 'dialer_proxy_unusable',
  // §538 — код НАШ, per-app: в `registry/warnings.json` его нет и не будет.
  // Схлопывание повторов внутри одной подписки делает только LxBox, и запись
  // в нормативном реестре объявила бы обеим сторонам норму, которой у
  // лаунчера нет. Таблица кодов реестром не гейтится (`registry_sync_test`
  // сверяет allowlists и backup-коды, не её), так что per-app код здесь
  // законен — текст живёт в классе, как у `Sections*Warning`.
  DuplicateNodeWarning: 'duplicate',
};

/// Код предупреждения: у реестра он поле, у рукописных классов — тип.
String? warningCodeOf(NodeWarning w) =>
    w is RegistryWarning ? w.code : kWarningCodes[w.runtimeType];

/// §472 шаг 1 — путь поля для рукописного класса, если поле класса И ЕСТЬ
/// этот путь; иначе `null`.
///
/// Таблица переехала из `test/contract/corpus_warnings.dart`
/// (`_legacyWarningPath`) по той же причине, по которой туда же переехала
/// [kWarningCodes]: у неё появился второй потребитель — дедуп предупреждений
/// при разборе (`parse_warnings.dart`). Санитайзер по дословной карте знает
/// адрес каждого поля, и без пути рукописного класса дедуп получался грубым:
/// код закрывался целиком, вместе с кодами реестра о ДРУГИХ полях (у naive
/// `tls_field_unsupported_naive` приходит на шесть путей разом). Две копии
/// таблицы разошлись бы на первом же новом классе.
///
/// Приписывать путь классу, который его не знает, нельзя: `path` нормативен
/// (PARSING_PRINCIPLES §6), и выдуманное значение расходилось бы с контрактом молча. Класс
/// вне таблицы пути не имеет — и в дедупе закрывает свой код целиком.
///
/// Кодов AWG здесь нет с контракта 1.1.33: классы сняты, и путь у них теперь
/// свой, реестровый, — `RegistryWarning` несёт его полем.
String? handwrittenWarningPath(NodeWarning w) => switch (w) {
      PacketEncodingUnknownWarning() => 'packet_encoding',
      UnknownFingerprintWarning() => 'tls.utls.fingerprint',
      RealityFingerprintWarning() => 'tls.utls.fingerprint',
      UnknownObfsWarning() => 'obfs.type',
      MissingObfsPasswordWarning() => 'obfs.password',
      // §467 — `field` класса это ИМЯ КЛЮЧА, под которым значение уезжает в
      // `transport` (его ставит тот же `putEnum`, что и предупреждение),
      // поэтому путь выводится из него, а не перечисляется вариантами.
      XhttpParamResetWarning(:final field) => 'transport.$field',
      _ => null,
    };
