Захват tcpdump на en0 Мака, udp port 2408, 08.10.2026 21:51–21:53, запущен владельцем (sudo).
Потоки по порту источника (все к 162.159.192.1:2408):
  49405  21:51:31  M wartune.mail.ru   PASS
  57171  21:51:37  C wartune.mail.ru   PASS
  49630  21:51:43  M apteka.ru         PASS
  50169  21:51:49  M wartune.mail.ru   FAIL
  50225  21:52:26  M 4pda.to           FAIL
  52016  21:52:43  M 4pda.to           FAIL
  53393  21:52:59  M 4pda.to           FAIL (хвост файла мог не сброситься до остановки tcpdump)
Файл .txt — tcpdump -n -tttt -r по тому же pcap. Разбор не делался.
