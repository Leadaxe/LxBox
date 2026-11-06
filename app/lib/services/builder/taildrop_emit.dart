/// §707 итер. 4 — «Allow Taildrop» узла Tailscale по умолчанию выключено
/// (контракт 1.1.149/1.1.150, решение владельца 02.11.2026).
///
/// Норма сборки: config-форма эмитит `disable_taildrop: true`, если в теле
/// нет явного `disable_taildrop: false`. Хранимое тело не трогается: галка
/// «вкл» пишет туда `false`, «выкл» снимает поле.
library;

import '../../models/singbox_entry.dart';
import '../contract/body_sanitizer.dart' show coreAtLeast;
import '../contract/registry.dart';

const _kField = 'disable_taildrop';

/// Подставить `disable_taildrop: true` endpoint'ам `tailscale` из [entries]
/// без явного `false`. Идёт ПОСЛЕ гейта реестра, поэтому `min_core` поля
/// (из реестра, не литералом) проверяется здесь же: на ядре старше поле не
/// пишется, и снимается и явное из тела — гейт реестра не правит авторское
/// тело тихими правками (§577), а ядро без поля отвергло бы весь конфиг.
///
/// Поле неизвестно реестру (реестр не загружен, контракт старше 1.1.150) —
/// ничего не делается: писать ядру поле, о котором нет сведений, нельзя.
void applyTaildropDefault(
  Iterable<SingboxEntry> entries, {
  required String coreVersion,
}) {
  if (!ContractRegistry.I.isLoaded) return;
  final field = ContractRegistry.I.schemaFor('tailscale')?.fields[_kField];
  if (field == null) return;
  final minCore = field.minCore;
  final coreOk = minCore == null || coreAtLeast(coreVersion, minCore);
  for (final e in entries) {
    final m = e.map;
    if (m['type'] != 'tailscale') continue;
    if (!coreOk) {
      m.remove(_kField);
      continue;
    }
    if (m[_kField] == false) continue;
    m[_kField] = true;
  }
}

/// Taildrop узла включён по хранимому телу: только явное `false`.
bool taildropAllowedByBody(Map<String, dynamic> body) =>
    body[_kField] == false;
