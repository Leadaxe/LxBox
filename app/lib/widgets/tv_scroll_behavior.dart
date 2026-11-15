import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// §736 — прокрутка списков перетаскиванием указателя-«мыши» на TV.
///
/// Flutter по умолчанию (`ScrollBehavior.dragDevices`) не тянет списки
/// мышью: колесо — да, перетаскивание — нет. Пульт Android TV в режиме
/// «мышь» (и аэромышь) приходит как `PointerDeviceKind.mouse`, колеса у него
/// нет — список нельзя было прокрутить вовсе (issue #220). На TV мышь
/// добавлена к устройствам перетаскивания; телефон не трогаем: там мышью
/// выделяют текст, и перетаскивание конкурировало бы с выделением.
class TvScrollBehavior extends MaterialScrollBehavior {
  const TvScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}
