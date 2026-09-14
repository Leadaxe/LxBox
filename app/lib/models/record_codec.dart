/// Кодек записей контракта 1.0 — реэкспорт модулей `codec/` для прежних
/// импортов (секции узла, LX Backup, парсер sing-box-конфига, тесты).
/// Новый код импортирует нужный модуль `codec/` напрямую.
library;

export 'codec/dns_record.dart';
export 'codec/record_read.dart';
export 'codec/rule_record.dart';
