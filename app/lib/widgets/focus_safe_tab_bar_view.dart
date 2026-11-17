import 'package:flutter/material.dart';

/// §744 — [TabBarView], у которого фокус живёт только на видимой вкладке.
///
/// Страница, на которой стоит фокус пульта или клавиатуры, держит себя живой
/// (подсветка фокуса у `InkWell` = keep-alive), и после переключения вкладки
/// мышью/тапом по `TabBar` фокус оставался на скрытой странице: стрелки и OK
/// продолжали менять настройки, которых пользователь уже не видит (issue #222,
/// третья жалоба — тема менялась с вкладки Subscriptions). Здесь каждая
/// неактивная страница обёрнута в [ExcludeFocus]: при смене вкладки фокус с
/// ушедшей страницы снимается, и обход фокуса пультом не заходит на скрытые.
///
/// Подменяет `TabBarView` один в один (`controller` или
/// `DefaultTabController`, `children`).
class FocusSafeTabBarView extends StatelessWidget {
  const FocusSafeTabBarView({
    super.key,
    this.controller,
    required this.children,
  });

  final TabController? controller;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ctl = controller ?? DefaultTabController.of(context);
    return TabBarView(
      controller: controller,
      children: [
        for (var i = 0; i < children.length; i++)
          ListenableBuilder(
            listenable: ctl,
            builder: (context, child) =>
                ExcludeFocus(excluding: ctl.index != i, child: child!),
            child: children[i],
          ),
      ],
    );
  }
}
