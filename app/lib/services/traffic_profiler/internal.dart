part of '../traffic_profiler.dart';

// ─────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────

// §044 — `_ConnMeta` (conn-id → package, TCP-атрибуция из router-лога) выпилен
// вместе с лог-питателем: TCP-owner идёт из ядра (CcConnection.packageName).
// §180 — `_DnsAccumulator` выпилен: cnameChain приходит целиком в
// `CcDnsQuery.answers` (ядро SPEC 018), ручная аккумуляция по connId не нужна.

class _ConnSnapshot {
  _ConnSnapshot({
    required this.id,
    required this.host,
    required this.ip,
    required this.port,
    required this.network,
    required this.chains,
    required this.detours, // §181
    this.outboundType, // §204
    required this.upBytes,
    required this.downBytes,
    required this.startedAt,
    required this.process,
    required this.confidence,
    required this.matchedVia,
    required this.rule,
    required this.rulePayload,
  });
  final String id;
  final String host;
  final String ip;
  final int port;
  final String network;
  final List<String> chains; // §174 — маршрут [node, …selectors]
  final List<String> detours; // §181 — detour-ось [detour, …наружу]
  final String? outboundType; // §204 — тип финального outbound (для detail 1:1)
  int upBytes;
  int downBytes;
  final DateTime startedAt;
  final String process;
  final ConfidenceLevel confidence;
  final String? matchedVia;
  final String rule;
  final String rulePayload;
}
