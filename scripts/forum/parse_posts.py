#!/usr/bin/env python3
"""Разбор HTML страницы темы 4PDA → отдельные файлы постов + индекс.

Форум отдаёт 403 на прямые запросы (стоит защита), поэтому HTML приходит со
stdin — его снимает браузер, который уже авторизован. См. fetch_thread.md.

Usage:
    python3 parse_posts.py --out docs/forum < page.html
    python3 parse_posts.py --out docs/forum --stdin-json < pages.json

Состояние (последний скачанный пост) — в <out>/state.json. Повторный прогон
той же страницы ничего не портит: файлы перезаписываются по номеру поста.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

try:
    from bs4 import BeautifulSoup
except ImportError:
    sys.exit("нужен bs4:  pip3 install beautifulsoup4")

# Служебные хвосты постов 4PDA — в сохранённый текст не идут.
CHROME = re.compile(
    r"^(В FAQ|ЖАЛОБА|ИМЯ|ЦИТИРОВАТЬ|ПЛОХО|ХОРОШО|ИЗМЕНИТЬ|УДАЛИТЬ|"
    r"Сообщение отредактировал.*|Прикрепленные изображения.*|"
    r"Просмотр профиля|Сообщения|Найти темы пользователя|"
    r"Найти сообщения пользователя|Cообщения пользователя в теме|"
    r"Группа:|Сообщений:.*|Регистрация:.*|Устройство:.*|"
    r"\d+|\(\d+%\)|Постоянный|online|offline|\[online\]|\[offline\])$"
)


def clean_lines(text):
    out = []
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or CHROME.match(line):
            continue
        out.append(line)
    return out


def parse_page(html):
    """→ [{num, entry, author, date, body}] в порядке появления."""
    soup = BeautifulSoup(html, "html.parser")
    posts = []
    for anchor in soup.select('a[name^="entry"]'):
        entry = anchor.get("name", "")
        table = anchor.find_parent("table")
        if not table:
            continue

        lines = clean_lines(table.get_text("\n"))
        if not lines:
            continue

        author = lines[0]
        num = None
        date = ""
        body_start = 1
        # Номер бывает и одной строкой («Сообщение #1304»), и двумя подряд
        # («Сообщение» / «#1304») — зависит от того, как снят HTML.
        for i, line in enumerate(lines[:12]):
            m = re.match(r"(?:Сообщение\s*)?#(\d+)$", line)
            if m:
                num = int(m.group(1))
                if i + 1 < len(lines):
                    date = lines[i + 1]
                body_start = i + 2
                break
        if num is None:
            continue

        # Профильный блок (группа/репутация/устройство) кончается строкой
        # «Репутация:»; тело поста идёт после неё.
        body = lines[body_start:]
        for i, line in enumerate(body[:15]):
            if line.startswith("Репутация"):
                body = body[i + 1 :]
                break

        posts.append(
            {
                "num": num,
                "entry": entry,
                "author": author,
                "date": date,
                "body": "\n".join(body).strip(),
            }
        )
    return posts


def write_posts(posts, outdir):
    postdir = os.path.join(outdir, "posts")
    os.makedirs(postdir, exist_ok=True)
    written = []
    for p in posts:
        path = os.path.join(postdir, f"{p['num']:05d}.md")
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# #{p['num']} — {p['author']}\n\n")
            f.write(f"- entry: `{p['entry']}`\n")
            f.write(f"- date: {p['date']}\n\n---\n\n")
            f.write(p["body"] + "\n")
        written.append(p)
    return written


def update_state(outdir, posts):
    path = os.path.join(outdir, "state.json")
    state = {"last_num": 0, "last_entry": "", "updated": "", "total": 0}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            state.update(json.load(f))

    if posts:
        newest = max(posts, key=lambda p: p["num"])
        if newest["num"] >= state["last_num"]:
            state["last_num"] = newest["num"]
            state["last_entry"] = newest["entry"]

    postdir = os.path.join(outdir, "posts")
    state["total"] = len([n for n in os.listdir(postdir) if n.endswith(".md")])
    state["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    return state


def rebuild_index(outdir):
    postdir = os.path.join(outdir, "posts")
    rows = []
    for name in sorted(os.listdir(postdir)):
        if not name.endswith(".md"):
            continue
        with open(os.path.join(postdir, name), encoding="utf-8") as f:
            head = f.readline().strip()
        m = re.match(r"# #(\d+) — (.+)", head)
        if m:
            rows.append((int(m.group(1)), m.group(2), name))

    with open(os.path.join(outdir, "INDEX.md"), "w", encoding="utf-8") as f:
        f.write("# Тема 1122662 — архив постов\n\n")
        f.write(f"Всего постов: {len(rows)}\n\n")
        f.write("| # | Автор | Файл |\n|---|---|---|\n")
        for num, author, name in rows:
            f.write(f"| {num} | {author} | [{name}](posts/{name}) |\n")
    return len(rows)


def parse_slim(text):
    """Разбор текстового экстракта: посты разделены @@@POST@@@, первая строка —
    `entryNNN` + начало текста поста (браузер склеивает их без переноса)."""
    posts = []
    for block in text.split("@@@POST@@@"):
        block = block.strip()
        if not block:
            continue
        m = re.match(r"(entry\d+)", block)
        if not m:
            continue
        entry = m.group(1)
        lines = clean_lines(block[len(entry) :])
        if not lines:
            continue

        author = lines[0]
        num = None
        date = ""
        body_start = 1
        for i, line in enumerate(lines[:12]):
            mm = re.match(r"(?:Сообщение\s*)?#(\d+)$", line)
            if mm:
                num = int(mm.group(1))
                if i + 1 < len(lines):
                    date = lines[i + 1]
                body_start = i + 2
                break
        if num is None:
            continue

        body = lines[body_start:]
        for i, line in enumerate(body[:15]):
            if line.startswith("Репутация"):
                body = body[i + 1 :]
                break

        posts.append(
            {
                "num": num,
                "entry": entry,
                "author": author,
                "date": date,
                "body": "\n".join(body).strip(),
            }
        )
    return posts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="docs/forum")
    ap.add_argument(
        "--stdin-json",
        action="store_true",
        help="на входе JSON-массив строк HTML (несколько страниц разом)",
    )
    ap.add_argument(
        "--slim",
        nargs="+",
        help="текстовые экстракты из браузера (посты через @@@POST@@@)",
    )
    ap.add_argument(
        "--jsonl",
        nargs="+",
        help="JSONL-экстракты из браузера: {n,a,d,e,b} на строку (основной путь)",
    )
    args = ap.parse_args()

    allposts = []
    if args.jsonl:
        for path in args.jsonl:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    r = json.loads(line)
                    if not r.get("n"):
                        continue
                    body = r.get("b", "")
                    # innerText склеивает абзацы: разрываем по «.Слово» и по
                    # служебному хвосту редактирования.
                    body = re.sub(r"(?<=[.!?»)])(?=[А-ЯЁA-Z])", "\n\n", body)
                    body = re.sub(r"\s*(Сообщение отредактировал .*)$", r"\n\n_\1_", body)
                    allposts.append(
                        {
                            "num": int(r["n"]),
                            "entry": r.get("e", ""),
                            "author": r.get("a", "") or "?",
                            "date": r.get("d", ""),
                            "body": body.strip(),
                        }
                    )
        pages = []
    elif args.slim:
        for path in args.slim:
            with open(path, encoding="utf-8") as f:
                allposts.extend(parse_slim(f.read()))
        pages = []
    else:
        raw = sys.stdin.read()
        pages = json.loads(raw) if args.stdin_json else [raw]

    for html in pages:
        allposts.extend(parse_page(html))

    written = write_posts(allposts, args.out)
    state = update_state(args.out, allposts)
    total = rebuild_index(args.out)

    print(f"обработано постов на входе: {len(allposts)}")
    print(f"записано файлов: {len(written)}")
    print(f"всего в архиве: {total}")
    print(f"последний пост: #{state['last_num']} ({state['last_entry']})")


if __name__ == "__main__":
    main()
