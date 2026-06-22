/// §160 — ось агрегации в Aggregated-режиме per-app trace: по доменам
/// или по IP. Вынесена отдельно чтобы и `AggregatedView`, и
/// `aggregate_detail_sheet` ссылались на один тип без циклов импорта.
enum AggAxis { domain, ip }
