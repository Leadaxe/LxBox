part of '../box_vpn_client.dart';


/// Разбивка памяти процесса приложения из native `getMemoryInfo` (§507:
/// AMS `getProcessMemoryInfo`, не голый `Debug.getMemoryInfo`). Все поля —
/// в байтах. Категории `summary.*` (PSS) плюс прямые счётчики native heap.
/// Ядро sing-box в том же процессе → его память внутри [nativeHeap]/
/// [nativeHeapAllocated].
class MemoryInfo {
  const MemoryInfo({
    this.totalPss = 0,
    this.totalSwap = 0,
    this.javaHeap = 0,
    this.nativeHeap = 0,
    this.code = 0,
    this.stack = 0,
    this.graphics = 0,
    this.privateOther = 0,
    this.system = 0,
    this.nativeHeapAllocated = 0,
    this.nativeHeapSize = 0,
  });

  /// summary.total-pss — суммарный PSS процесса.
  final int totalPss;
  final int totalSwap;
  final int javaHeap;
  final int nativeHeap;
  final int code;
  final int stack;
  final int graphics;
  final int privateOther;
  final int system;

  /// Аллоцированный native heap (malloc) — прямой счётчик, не PSS.
  final int nativeHeapAllocated;
  final int nativeHeapSize;

  static int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

  factory MemoryInfo.fromMap(Map<dynamic, dynamic> m) => MemoryInfo(
        totalPss: _int(m['totalPss']),
        totalSwap: _int(m['totalSwap']),
        javaHeap: _int(m['javaHeap']),
        nativeHeap: _int(m['nativeHeap']),
        code: _int(m['code']),
        stack: _int(m['stack']),
        graphics: _int(m['graphics']),
        privateOther: _int(m['privateOther']),
        system: _int(m['system']),
        nativeHeapAllocated: _int(m['nativeHeapAllocated']),
        nativeHeapSize: _int(m['nativeHeapSize']),
      );
}


/// §455 — вердикт `Libbox.checkConfig()`: [ok] — ядро приняло; иначе [error]
/// — отказ словами ядра (unknown field, отвергнутая опция, битый ключ).
final class CoreCheck {
  const CoreCheck({required this.ok, this.error = ''});
  final bool ok;
  final String error;
}
