/// §757 волна 4 — подписи условий и полей формы правила.
///
/// Таблица условий несёт английские подписи справочно; у LxBox свои строки
/// (через локализатор). Сопоставление — по английской подписи таблицы, имён
/// ключей здесь нет. Подпись, которой здесь нет (реестр новее клиента), —
/// текст таблицы как есть.
library;

import '../../services/contract/rule_conditions.dart';
import '../../services/l10n/locale_controller.dart';

/// Подпись условия (рамка, пункт меню «+ Condition»).
String condLabel(RuleCondition c) => switch (c.label) {
      'Destination / Rule sets' => getLocalText.s("Destination / Rule sets"),
      'Port' => getLocalText.s("Port"),
      'Source' => getLocalText.s("Source"),
      'Source port' => getLocalText.s("Source port"),
      'Process' => getLocalText.s("Process"),
      'Protocol' => getLocalText.s("Protocol"),
      'Network' => getLocalText.s("Network"),
      'Inbound' => getLocalText.s("Inbound"),
      'Wi-Fi' => getLocalText.s("Wi-Fi"),
      'Apps' => getLocalText.s("Apps"),
      'Network type' => getLocalText.s("Network type"),
      _ => c.label,
    };

/// Подпись поля ключа.
String condKeyLabel(RuleConditionKey k) => switch (k.label) {
      // У LxBox наборы — только по ссылке, файла с устройства нет.
      'Rule sets — URL or file (one per line)' =>
        getLocalText.s("Rule sets — URL (one per line)"),
      'Domains' => getLocalText.s("Domains"),
      'Domain suffixes' => getLocalText.s("Domain suffixes"),
      'Domain keywords' => getLocalText.s("Domain keywords"),
      'Domain regex' => getLocalText.s("Domain regex"),
      'IP addresses / CIDR' => getLocalText.s("IP addresses / CIDR"),
      'Private addresses' => getLocalText.s("Private addresses"),
      'Ports' => getLocalText.s("Ports"),
      'Port ranges' => getLocalText.s("Port ranges"),
      'Source IP addresses / CIDR' =>
        getLocalText.s("Source IP addresses / CIDR"),
      'Private source addresses' => getLocalText.s("Private source addresses"),
      'Source ports' => getLocalText.s("Source ports"),
      'Source port ranges' => getLocalText.s("Source port ranges"),
      'Name' => getLocalText.s("Name"),
      'Path' => getLocalText.s("Path"),
      'Path regex' => getLocalText.s("Path regex"),
      'Protocols' => getLocalText.s("Protocols"),
      'Networks' => getLocalText.s("Networks"),
      'Inbound tags' => getLocalText.s("Inbound tags"),
      'SSID' => getLocalText.s("SSID"),
      'BSSID' => getLocalText.s("BSSID"),
      'Packages' => getLocalText.s("Packages"),
      'Package regex' => getLocalText.s("Package regex"),
      'Network types' => getLocalText.s("Network types"),
      'Metered network' => getLocalText.s("Metered network"),
      '' => k.key,
      _ => k.label,
    };
