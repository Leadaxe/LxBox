/// Ключи верхнего уровня `lxbox_settings.json` в форме контракта 1.0
/// (§439 §1.1): одно место на репозитории хранения, миграцию и Debug API.
///
/// Имена формы 2.23.2 (`server_lists`, `chains`, `custom_rules`,
/// `dns_options`) здесь не объявляются: после 2.23.3 их знает только
/// читатель старой формы (`storage_migration/`).
library;

/// Признак формы документа. Нет ключа — форма 2.23.2.
const String kStorageVersionKey = 'storage_version';

/// Текущая форма: записи `sources[]`, `rules[]`, `dns{}` контракта 1.0.
const int kStorageVersion = 1;

/// Источники (подписка, сервер, папка), хвостом — цепочки в своём порядке
/// (§439 §2.3 п. 7).
const String kSourcesKey = 'sources';

/// Правила маршрута.
const String kRulesKey = 'rules';

/// DNS-записи: объект `{servers[], rules[]}`.
const String kDnsKey = 'dns';

/// Серверы внутри [kDnsKey].
const String kDnsServersKey = 'servers';

/// Правила внутри [kDnsKey].
const String kDnsRulesKey = 'rules';
