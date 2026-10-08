Плечо M, нативные прогоны с Мака, 08.10.2026 20:33–20:48, ядро 1.14.2-lx.12, проводной канал.
M = Chrome 133 QUIC ClientHello (uTLS, X25519MLKEM768 сохранён, ALPN h3) в двух Initial по порядку:
i1 = pn0 CRYPTO[off=0 len=1211], i2 = pn1 CRYPTO[off=1211 …] + PADDING, оба 1250 байт, общий DCID.
Пресет AWG: jc=4 jmin=40 jmax=70 s1=s2=0 h1..h4=1..4; аккаунты v2 (B для M, C и P для контролей).

Серии (сырые строки RESULT в results_*.txt; логи процессов в logs/, префиксы: log_N = серия 1,
log_x/log_y = перекрёстные аккаунт×блоб, log_z = свежие блобы, log_r = redcid/i1only):
 1. results_1_M_vs_C_P.txt — 3 раунда P,C,M по обоим SNI (+2 M): P 0/3, C 6/6, M apteka 4/4, M wartune 0/4.
 2. перекрёстная: M-блоб wartune на C-аккаунте PASS/FAIL, C-блоб на B-аккаунте PASS×2, M wartune свой 1/3.
 3. свежие блобы fresh1..3 ×2: apteka 6/6 PASS; wartune f1 0/2, f2 2/2, f3 0/2; исходные orig: apteka PASS, wartune FAIL.
 4. results_4_redcid_i1only.txt — тот же ClientHello с новым DCID: origW 1/2, f1W 0/2; только i1 без i2: origW 0/2, f1W 2/2; origW как есть 1/2.
Сигнатура провала (debug-лог): «received handshake response», затем outbound 1.1.1.1:443 молчит до таймаута — как у плеча J.
Карта расширений ClientHello относительно границы 1211 (SNI/ECH в p1/p2) исход не объясняет — см. вывод TestExpArmMInspect в exp_arm_m_lx_test.go.txt.
Генератор: exp_arm_m_lx_test.go.txt (временный тест ядра, tags with_awg,with_utls, не закоммичен).
