import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// §736 — прокрутка списков перетаскиванием указателя-«мыши».
///
/// Flutter по умолчанию (`ScrollBehavior.dragDevices`) не тянет списки
/// мышью: колесо — да, перетаскивание — нет. Пульт Android TV в режиме
/// «мышь» (и аэромышь) приходит как `PointerDeviceKind.mouse`, колеса у него
/// нет — список нельзя было прокрутить вовсе (issue #220). Мышь добавлена к
/// устройствам перетаскивания на всех устройствах (решение владельца
/// 15.11.2026), как в нативном Android. Цена: в поле ввода перетаскивание
/// мышью прокручивает текст, а не выделяет его.
class MouseDragScrollBehavior extends MaterialScrollBehavior {
  const MouseDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}
