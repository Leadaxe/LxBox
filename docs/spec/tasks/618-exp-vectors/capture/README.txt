chrome_quic_2026-10-08.pcap — tcpdump en0, udp port 443, системный Chrome на HTTP/3 к Google/Cloudflare.
  Первый бросок к 142.251.151.119: 3× Initial 1250 байт, token 70, pn 1/2/3, ClientHello 2501.
  Карта фреймов — в 618-md «Что делает настоящий Chrome 133».
warp_m_2026-10-08.pcap — tcpdump en0, udp port 2408, наши плечи M/C/apteka/4pda к WARP.
  Потоки по src-порту: см. транскрипт. Разбор поведения узла не велся (Scope-note).
Чтение pcap без root: tcpdump -n -r <file>. Декодер Initial — exp_generator.go.txt (TestExpDecodeRealChrome).
