# 127 — Генератор псевдо-имён и псевдо-доменов

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-06-15 |
| Триггер | Для junk-обфускации WARP ([§126](126-warp-amneziawg-obfuscation.md)) SIP-шаблон требует правдоподобные, но НЕ узнаваемые user/host (нельзя `bob@biloxi.com` — это RFC-маяк). Нужен переиспользуемый генератор произносимых псевдо-имён и псевдо-доменов/IP. |
| Связанные | [§126](126-warp-amneziawg-obfuscation.md) (потребитель — SIP junk-шаблон) |
| Затронутые файлы | новый `app/lib/services/util/pseudo_gen.dart` (не привязан к WARP — общий util); тесты `app/test/services/pseudo_gen_test.dart` |

## Назначение

Самостоятельный генератор:
- **`genWord()`** — произносимое слоговое слово (6–13 букв), выглядит как реальное имя.
- **`genUser()`** — псевдо-username (одиночный или составной `word_word`).
- **`genHost()`** — псевдо-SIP-host: домен 2/3-уровневый, sip-поддомен или публичный IP.

Главная задача — **правдоподобность без узнаваемости**: ни захардкоженных строк (DPI-маяк), ни мусора (`7f3a9c`), ни приватных IP (выдают подделку). Каждый вызов уникален (`Random.secure()`).

## Алгоритм

### genWord()

```
word = C + V + [ (60%: C | 40%: ONSET) + V ] × {2..3} + (50%: tail)
tail = 30%: CODA | 70%: C
```

| Набор | Значения | Назначение |
|---|---|---|
| `C` (согласные) | `b c d f g h j k l m n p r s t v w z` | без `q x y` — непроизносимые сочетания |
| `V` (гласные) | `a e i o u` | |
| `ONSET` (кластеры в **начале** слога) | `br tr cr dr fr gr pr st sp sk sl sm sn bl cl fl gl pl tw sh` | произносимые онсеты (перед гласной) |
| `CODA` (кластеры в **конце** слова) | `lk sk st nk sh nt rk ng` | произносимые коды (после гласной): `silk`/`bank`/`song`. `lk` — ТОЛЬКО кода, НЕ онсет |

- Блок `(C|ONSET)+V` повторяется **2–3** раза → длина 6–13 букв (мин `C+V`+2×`C+V`=6; макс `C+V`+3×`ONSET+V`+`CODA`=13).
- Старт всегда `C+V`; хвост опционален (50%): либо одиночная согласная (70%), либо кода-кластер (30%).
- Примеры: `kalenot`, `gablegont`, `tismutriri`, `nukepebe`, `wozupetul`.

### genUser()

`genWord()`; с вероятностью **30%** — составное `genWord()_genWord()`.
Примеры: `nazope`, `gubahaslu`, `fibitrini_hitrislet`, `dipasmilash`.

### genHost()

| Доля | Тип | Пример |
|---|---|---|
| 30% | 3-уровневый домен | `gosabletwiz.majatabref.org` |
| 30% | публичный IP | `159.124.167.83` |
| 30% | 2-уровневый домен | `decrefost.net` |
| 10% | sip-поддомен | `sip.jutesmovul.net` |

- TLD: `com net org io co`.
- **IP — только публичные.** Исключить (иначе VoIP-подделка очевидна): `0.x`, `10.x`, `127.x`, `172.16–31.x`, `192.168.x`, `169.254.x`, `100.64–127.x`, `≥224.x` (multicast/reserved).

## Эталонная реализация (Python — референс для Dart-порта)

```python
import secrets

CONS  = list("bcdfghjklmnprstvwz")   # без q x y
VOW   = list("aeiou")
ONSET = ["br","tr","cr","dr","fr","gr","pr","st","sp","sk","sl","sm",
         "sn","bl","cl","fl","gl","pl","tw","sh"]   # начало слога
CODA  = ["lk","sk","st","nk","sh","nt","rk","ng"]   # конец слова
TLD   = ["com","net","org","io","co"]

def _pick(seq): return secrets.choice(seq)
def _chance(pct): return secrets.randbelow(100) < pct

def gen_word() -> str:
    s = _pick(CONS) + _pick(VOW)                          # C + V
    for _ in range(2 + secrets.randbelow(2)):             # 2..3 блока
        head = _pick(CONS) if _chance(60) else _pick(ONSET)
        s += head + _pick(VOW)                            # (C|ONSET) + V
    if _chance(50):                                       # 50% хвост
        s += _pick(CODA) if _chance(30) else _pick(CONS)
    return s

def gen_user() -> str:
    u = gen_word()
    if _chance(30):                                       # 30% составной
        u += "_" + gen_word()
    return u

def _is_reserved(a, b) -> bool:
    if a in (0, 10, 127): return True
    if a == 172 and 16 <= b <= 31: return True
    if a == 192 and b == 168: return True
    if a == 169 and b == 254: return True
    if a == 100 and 64 <= b <= 127: return True
    if a >= 224: return True                              # multicast/reserved
    return False

def gen_public_ip() -> str:
    while True:
        a = 1 + secrets.randbelow(223)
        b = secrets.randbelow(256)
        if _is_reserved(a, b): continue
        return f"{a}.{b}.{secrets.randbelow(256)}.{1 + secrets.randbelow(254)}"

def gen_host() -> str:
    r = secrets.randbelow(100)
    if r < 30: return f"{gen_word()}.{gen_word()}.{_pick(TLD)}"   # 3-уровневый
    if r < 60: return gen_public_ip()                            # IP
    if r < 90: return f"{gen_word()}.{_pick(TLD)}"               # 2-уровневый
    return f"sip.{gen_word()}.{_pick(TLD)}"                      # sip-поддомен
```

## Dart-порт — соответствия

| Python | Dart |
|---|---|
| `secrets.choice(seq)` | `seq[_rng.nextInt(seq.length)]`, `_rng = Random.secure()` |
| `secrets.randbelow(n)` | `_rng.nextInt(n)` |
| `_chance(pct)` | `_rng.nextInt(100) < pct` |
| строки/списки | `const List<String>` для наборов |

API Dart: `class PseudoGen { static String word(); static String user(); static String host(); }` (или top-level функции). `Random.secure()` — один статический инстанс.

## Acceptance

- [x] `word()` — только `[a-z]`, длина 6–13, начинается с согласной, произносимо (нет `q/x/y`, нет онсета `lk` в начале).
- [x] `user()` — ~30% содержат один `_`; обе части валидны как `word()`.
- [x] `host()` — распределение ~30/30/30/10; IP всегда публичный (прогнать 1000× — ни одного зарезервированного).
- [x] Два последовательных вызова дают разные значения (Random.secure, не seeded).
- [x] Нет захардкоженных RFC-строк (`bob@biloxi.com` и т.п.).

**Реализовано (2026-06-15):** `app/lib/services/util/pseudo_gen.dart` — `class PseudoGen { static word(); user(); host(); publicIp(); }`. Тесты `app/test/services/pseudo_gen_test.dart` (7 тестов, статистические прогоны 1000–5000×). Потребитель — `awg_junk.dart` SIP-шаблон ([§126](126-warp-amneziawg-obfuscation.md)).

## NB

- Генератор **не** криптографически «правильный» (это junk, не секрет), но `Random.secure()` берём чтобы не было предсказуемой seeded-последовательности → нет общей сигнатуры между юзерами.
- Длина/доли — подобраны на глаз под реализм; тюнить при необходимости (см. историю обсуждения §126).
