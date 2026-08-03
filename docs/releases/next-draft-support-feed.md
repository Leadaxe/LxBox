# Черновик заметок к следующему релизу — support-лента (§356/§357/§362)

Готовые куски для `RELEASE_NOTES.md` (EN + RU). Переносить при подготовке
релиза по RELEASE_PROCESS §2.3, после чего этот файл удалить.

---

## 💬 Added — messages from the author: a feed instead of one window

Every few days of use the app shows a message from the author: where the guide
lives, where the community is, how to help the project. It used to be a single
window in Russian only, and "Don't show again" silenced it forever — an
English-speaking user got Cyrillic, and there was no way to say anything new.

Now it's a queue. Each message arrives in the interface language (Russian or
English), takes the full screen instead of a cramped popup, and waits its turn:
the next one appears only after the VPN has clocked its hours since the previous
"Got it". Updating the app shifts the countdown — a new version never dumps the
whole queue at once.

The "Got it" button stays disabled for the first few seconds and counts down, so
a message can't be dismissed unseen. "Later" postpones the whole feed; the
cross closes it until the next launch without marking anything.

Buttons can now lead inside the app — open the traffic profiler or DNS settings
straight away — offer a server for adding (the link is prefilled, you press "+"
yourself), or send the app link through the system share sheet. A button with an
action an older app version doesn't know is simply not shown.

Usage time is finally counted honestly: it used to tick only while the app was
open, so for anyone who starts the VPN and swipes the app away it barely moved.
Now the missing time is topped up from the tunnel's own uptime, kept by the
service itself.

---

## 💬 Добавлено — сообщения от автора: лента вместо одного окна

Приложение раз в несколько дней работы показывает сообщение от автора: как
устроена инструкция, где сообщество, чем помочь проекту. Раньше это было
одно-единственное окно на русском языке, а кнопка «Не показывать» гасила его
навсегда — англоязычный пользователь получал кириллицу, а сказать что-то новое
было нельзя.

Теперь это очередь сообщений. Каждое приходит на языке интерфейса, показывается
во весь экран, а не тесной всплывашкой, и ждёт своей очереди: следующее
появится, только когда VPN наработает положенные часы после предыдущего
«Прочитал». Обновление приложения отсчёт сдвигает — после установки новой
версии лента не вываливается разом.

Кнопка «Прочитал» первые секунды неактивна и отсчитывает время: сообщение
нельзя смахнуть, не увидев. «Позже» откладывает всю ленту, крестик закрывает до
следующего запуска, ничего не помечая.

Кнопки в сообщении теперь умеют вести внутрь приложения — например, сразу
открыть профайлер трафика или настройки DNS, — предлагать сервер к добавлению
(ссылка подставляется в поле, добавляет пользователь сам) и отправлять ссылку
на приложение через системное «Поделиться». Кнопка с незнакомым действием на
старой версии приложения просто не показывается.

Счёт времени работы стал честным: раньше он шёл, только пока приложение
открыто, и у тех, кто включает VPN и убирает приложение из недавних, почти не
двигался. Теперь недостающее доливается из времени работы туннеля, которое
ведёт сама служба.
