import 'package:flutter/material.dart';

/// §735 — фирменный seed приложения (палитра по умолчанию).
const Color kAppSeedColor = Colors.indigo;

/// §735 — seed темы: акцент системной палитры (Material You), только если
/// опция «System colors» включена и устройство палитру отдаёт (Android 12+,
/// не TV); иначе — [kAppSeedColor]. Схема строится `ColorScheme.fromSeed`
/// с вариантом по умолчанию `tonalSpot` — тем же, которым Android строит
/// системную палитру из обоев.
Color appThemeSeed({required bool dynamicColor, Color? systemAccent}) =>
    dynamicColor && systemAccent != null ? systemAccent : kAppSeedColor;
