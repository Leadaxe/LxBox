import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';

void main() {
  // Коды, у которых рукописный класс снят: `byCode` обязан не только вернуть
  // `RegistryWarning`, но и переложить путь/значение под ИМЯ, которое код
  // объявил в `params` реестра. Без этого текст доехал бы до человека с
  // буквальным `{query_name}` — реестр тут не поможет, подстановку ставит
  // приложение.
  group('byCode — именованные параметры снятых классов', () {
    test('ech_ignored: query_name = имя параметра ссылки', () {
      final w = NodeWarning.byCode('ech_ignored',
          path: 'ech', value: 'encryptedsni.com') as RegistryWarning;
      expect(w.code, 'ech_ignored');
      expect(w.path, 'ech');
      expect(w.value, 'encryptedsni.com');
      expect(w.params['query_name'], 'ech');
    });

    test('ws_early_data_converted: max_early_data = что получилось', () {
      final w = NodeWarning.byCode('ws_early_data_converted',
          path: 'path', value: '2560') as RegistryWarning;
      expect(w.params['max_early_data'], '2560');
    });

    test('naive_extra_headers_invalid: entry = отброшенная пара', () {
      final w = NodeWarning.byCode('naive_extra_headers_invalid',
          path: 'extra-headers', value: 'no-colon') as RegistryWarning;
      expect(w.params['entry'], 'no-colon');
    });

    // Контракт 1.1.33 переписал тексты обоих кодов AWG с `{path}`/`{value}`
    // и последствием для рукопожатия; классы сняты. Своего имени им не нужно
    // — оба плейсхолдера подставляются всегда (`text_params_implicit`).
    test('awg_header_invalid: RegistryWarning с путём и значением', () {
      final w = NodeWarning.byCode('awg_header_invalid',
          path: 'h1', value: '5-1') as RegistryWarning;
      expect(w.code, 'awg_header_invalid');
      expect(w.path, 'h1');
      expect(w.value, '5-1');
      expect(w.params, isEmpty);
    });
  });
}
