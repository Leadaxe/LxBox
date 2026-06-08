part of '../traffic_profiler.dart';

// ─────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────

class _ConnMeta {
  _ConnMeta(this.process, this.firstSeen);
  final String process;
  final DateTime firstSeen;
}

class _DnsAccumulator {
  _DnsAccumulator({required this.domain, required this.firstTs})
      : lastTs = firstTs,
        lastResolvedName = domain;
  final String domain;
  String lastResolvedName;
  final List<String> cnameChain = <String>[];
  final Set<String> ips = <String>{};
  DateTime firstTs;
  DateTime lastTs;
}

class _ConnSnapshot {
  _ConnSnapshot({
    required this.id,
    required this.host,
    required this.ip,
    required this.port,
    required this.network,
    required this.chains,
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
  final List<String> chains;
  int upBytes;
  int downBytes;
  final DateTime startedAt;
  final String process;
  final ConfidenceLevel confidence;
  final String? matchedVia;
  final String rule;
  final String rulePayload;
}
