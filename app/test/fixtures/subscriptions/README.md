# Subscription fixtures

Тела подписок целиком (base64 или plain-URI list). Используются для parity-тестов v1↔v2 в Фазе 3.

Текущий корпус — **синтетика** (собирается из `base64/plain_uri_list.txt` + генерируемые комбинации). Когда появятся анонимизированные реальные подписки, класть их сюда с именем `real_<provider>_<date>.txt`.

Формат:
- `.txt` — исходное тело (как приходит с сервера).
- `.headers.json` — опционально, HTTP-заголовки (`subscription-userinfo`, `profile-title`, `profile-update-interval`, `profile-web-page-url`) для проверки `SubscriptionMeta`.
