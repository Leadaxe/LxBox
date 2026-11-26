# 763 — OpenConnect: снять отпечаток сертификата с сервера кнопкой в форме

| | |
|---|---|
| **Статус** | Done — в ветке `claude/763-fetch-cert-pin`, на телефоне не проверено |
| **Дата** | 2026-11-26 |
| **Повод** | Решение владельца 26.11.2026: отпечаток для «Pinned fingerprint» пользователь должен получать в приложении, а не искать сам |
| **Связанные** | 654 (форма узла OpenConnect); ядро: `docs/configuration/endpoint/openconnect.md` тега `v1.14.4-lx.37` (`tls.peer_fingerprint`) |

## Docs to update

- `docs/USER_GUIDE.md` / `.ru.md` — карточка OpenConnect, одна-две фразы про кнопку.
- `CHANGELOG.md` (Unreleased).

## Problem

В форме узла OpenConnect (вкладка протокола на экране сервера и вкладка
Source правки узла) группа «Server certificate» предлагает вариант «Pinned
fingerprint» с полем `tls.peer_fingerprint`. Значение пользователь должен
взять где-то сам (openssl, админ шлюза). Приложению сервер доступен — снять
отпечаток оно может само.

## Diagnosis

- Поле `tls.peer_fingerprint` — `listable_string` реестра
  (`app/assets/contract/registry/protocols/openconnect.json`), вариант
  `pinned` группы `server_cert_check`. Ядро принимает четыре формата, в том
  числе `pin-sha256:<base64>` — Base64 SHA-256 от DER SubjectPublicKeyInfo.
  Отпечаток SPKI переживает перевыпуск сертификата с тем же ключом; формат
  проходит `pattern` реестра.
- `dart:io` отдаёт `X509Certificate` пира (`der`, `subject`, `issuer`,
  `endValidity`) даже при непрошедшей проверке цепочки, если
  `onBadCertificate` вернул `true`. SPKI вырезается из DER сертификата
  разбором TLV (без перекодирования — хешируются исходные байты).
- `SecureSocket.connect` берёт SNI из `host`, отдельного аргумента нет.
  Поэтому при заданном `tls.server_name`: `Socket.connect(host, port)` +
  `SecureSocket.secure(socket, host: sni)`. Тот же путь и без SNI — один код.

## Solution

1. Сервис `app/lib/services/tls/cert_pin_fetcher.dart` (без Flutter):
   - `parseCertPinTarget(server)` — адрес из поля `server`: `host`,
     `host:port`, `https://host[:port][/path]`, `[v6]:port`, голый IPv6;
     порт по умолчанию 443; пусто/негодно — `null`.
   - `CertPinFetcher` (интерфейс, подменяется в тестах) и
     `IoCertPinFetcher`: TCP-подключение с таймаутом 10 с, TLS-рукопожатие
     с таймаутом 10 с, SNI = `tls.server_name` формы, иначе хост; цепочка не
     проверяется; берётся первый сертификат (лист); сокет закрывается сразу.
   - Результат `CertPinInfo`: subject (CN, иначе строка целиком), issuer
     (так же), `notAfter`, `pin` = `pin-sha256:<base64>`.
   - Ошибка — `CertPinException` с видом: нет адреса, не резолвится,
     таймаут, не TLS, прочее.
2. Форма (`app/lib/widgets/openconnect_form.dart`): под полем варианта
   «Pinned fingerprint» — `TextButton.icon` «Fetch from server». Во время
   запроса — индикатор, кнопка неактивна. Ошибка — короткая строка под
   кнопкой цветом ошибки, без исключений наружу.
3. Перед вставкой — диалог «Pin this certificate?»: Issued to, Issued by,
   Valid until (`yyyy-MM-dd`), Fingerprint (выделяемый текст); кнопки
   «Cancel» / «Use». Молча ничего не вставляется: это доверие при первом
   подключении, пользователь видит, что закрепляет.
4. «Use» → `tls.peer_fingerprint` = одно значение (список из одного
   элемента, как даёт поле ввода варианта), прежние значения заменяются;
   выбран вариант «Pinned fingerprint»; текст поля обновлён; новое тело уходит
   владельцу формы (`onChanged`) — экран пишет его в Source, как правку
   любого поля.
5. Fetcher — необязательный параметр `OpenConnectForm.certPinFetcher`, по
   умолчанию `IoCertPinFetcher`; экраны не меняются.

Маршрут подключения: из процесса окна приложения, как обычный сокет. При
включённом VPN запрос идёт через туннель по правилам маршрутизации (приложение
само себя из VPN не исключает); без VPN — напрямую. Отдельной логики нет.

## Risks and edge cases

- TOFU: при перехвате на пути пользователь закрепит чужой ключ. Смягчение —
  диалог с CN/issuer/сроком; решение за пользователем.
- Шлюз за SNI-маршрутизатором отдаёт разный сертификат по имени — поэтому
  SNI из `tls.server_name`.
- Берётся только лист цепочки. Пин промежуточного CA не предлагается.
- Сервер с клиентским сертификатом (mTLS) может оборвать рукопожатие до
  отдачи сертификата — тогда «не TLS»; сертификат пира `dart:io` обычно
  получает раньше запроса клиентского.
- Фикстуры тестов — только сертификаты (DER), закрытые ключи не коммитятся.

## Verification

- Юнит: SPKI и pin на фикстурах `app/test/fixtures/cert_pin_rsa.der`,
  `cert_pin_ec.der` (ожидаемое — `openssl x509 -pubkey -noout | openssl pkey
  -pubin -outform DER | openssl dgst -sha256 -binary | base64`); pin проходит
  `pattern` реестра; разбор адреса; CN из DN.
- Виджет: подменённый fetcher → диалог с данными → «Use» → значение в
  `tls.peer_fingerprint`; «Cancel» — тело не меняется; ошибка → текст;
  во время запроса кнопка неактивна.
- Локально, один раз (сетевого теста в CI нет): `fw2.soft-master.com:42319` →
  `pin-sha256:+VQgO8BfZcupR2G08jGN4CToJsOx69uWRi6QGbPywfI=`, CN
  `fw2.soft-master.com`, issuer `SSL.com TLS Issuing RSA CA R1`, до
  2027-05-28 — совпадает с ожидаемым. Там же: несуществующий хост →
  «не резолвится», `example.com:80` → «не TLS».

## Unresolved

- На телефоне (с VPN и без) не проверено.
