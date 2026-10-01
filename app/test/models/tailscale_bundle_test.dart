import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/tailscale_bundle.dart';

/// §449 — каноническая связка Tailscale (правило, DNS-сервер, DNS-правило)
/// упразднена §575: её даёт пресет шаблона (§578). Здесь остаётся только
/// hostname по умолчанию.
void main() {
  group('§449 — hostname по умолчанию', () {
    test('модель как есть → префикс и нижний регистр через дефисы', () {
      expect(defaultTailscaleHostname('Pixel 7 Pro'), 'LxBox-pixel-7-pro');
      expect(defaultTailscaleHostname('CPH2411'), 'LxBox-cph2411');
    });

    test('подчёркивания и серии разделителей схлопываются', () {
      expect(defaultTailscaleHostname('sdk_gphone64_arm64'),
          'LxBox-sdk-gphone64-arm64');
      expect(defaultTailscaleHostname('Galaxy   S24  Ultra'),
          'LxBox-galaxy-s24-ultra');
    });

    test('края очищаются', () {
      expect(defaultTailscaleHostname(' -Nexus 5X- '), 'LxBox-nexus-5x');
    });

    test('модель без латиницы и цифр схлопывается целиком → голый префикс', () {
      expect(defaultTailscaleHostname('Телефон'), 'LxBox');
      expect(defaultTailscaleHostname('📱'), 'LxBox');
      expect(defaultTailscaleHostname('___'), 'LxBox');
    });

    test('пустая модель → голый префикс', () {
      expect(defaultTailscaleHostname(''), 'LxBox');
    });

    test('длинная модель обрезается в DNS-метку без хвостового дефиса', () {
      final name = defaultTailscaleHostname('a' * 100);
      expect(name.length, kTailscaleHostnameMaxLength);
      expect(name.startsWith('LxBox-a'), isTrue);

      // Обрезка пришлась на разделитель — дефис на конце не остаётся.
      final onBoundary = defaultTailscaleHostname('${'b' * 56} tail');
      expect(onBoundary.endsWith('-'), isFalse);
      expect(onBoundary.length <= kTailscaleHostnameMaxLength, isTrue);
    });
  });
}
