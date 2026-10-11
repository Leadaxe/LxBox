#!/usr/bin/env python3
"""Скачивание артефакта GitHub Actions параллельными Range-запросами.

Запуск:  python3 dl_artifact.py <artifact_id> <size_bytes> [owner/repo]

Ключевое (см. SKILL.md): на azure-блоб Authorization НЕ отправляем — он ломает
подпись SAS (401/403). Токен нужен только для запроса подписанного URL у API.

Результат: /tmp/apks-new.zip (распакованный в /tmp/artx).
"""
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

TOK = os.environ.get('GITHUB_TOKEN') or open(
    os.path.expanduser('~/.hermes/.gh_token')).read().strip().strip('\r\n')
ART_ID = sys.argv[1]
SIZE = int(sys.argv[2])
REPO = sys.argv[3] if len(sys.argv) > 3 else 'mx57/LxBox'

API = f'https://api.github.com/repos/{REPO}/actions/artifacts/{ART_ID}/zip'
OUT = '/tmp/apks-new.zip'
WORK = '/tmp/parart'
N = 12
os.makedirs(WORK, exist_ok=True)


def fresh_url():
    """Подписанный URL блоба. -L следует за 302, -I берёт только заголовки."""
    r = subprocess.run(
        ['curl', '-s', '-o', '/dev/null', '-w', '%{url_effective}',
         '--max-time', '45', '-L', '-I',
         '-H', f'Authorization: Bearer {TOK}',
         '-H', 'Accept: application/vnd.github+json', API],
        capture_output=True, text=True, timeout=70)
    return r.stdout.strip()


def get_range(url, start, end, dest, timeout=600):
    """Качает диапазон. БЕЗ Authorization — SAS уже в URL."""
    subprocess.run(
        ['curl', '-sS', '-L', '--http1.1', '--max-time', str(timeout),
         '-r', f'{start}-{end}', '-o', dest, url],
        capture_output=True, timeout=timeout + 30)
    return os.path.exists(dest) and os.path.getsize(dest) == (end - start + 1)


def fetch_range(holder, start, end, dest):
    for _ in range(60):
        if get_range(holder[0], start, end, dest):
            return True
        try:
            nu = fresh_url()          # SAS протух/отказ — берём свежий
            if nu and len(nu) > 100:
                holder[0] = nu
        except Exception:
            pass
        time.sleep(1)
    return False


def main():
    url = fresh_url()
    if len(url) < 100:
        print('URL НЕ ПОЛУЧЕН (проверь токен и sr=b в URL)', flush=True)
        return 1
    print('url len:', len(url), flush=True)
    holder = [url]
    chunk = (SIZE + N - 1) // N
    jobs = [(i * chunk, min(i * chunk + chunk - 1, SIZE - 1), f'{WORK}/p{i}')
            for i in range(N)]
    print(f'старт {N} потоков по {chunk // 1024 // 1024} МБ', flush=True)
    with ThreadPoolExecutor(max_workers=N) as ex:
        futs = {ex.submit(fetch_range, holder, s, e, d): d for s, e, d in jobs}
        results = {d: f.result() for f, d in futs.items()}
    for d, ok in sorted(results.items()):
        print(('OK ' if ok else 'FAIL ') + d, flush=True)
    if not all(results.values()):
        print('ЕСТЬ ПРОВАЛЫ: докачай хвосты (см. SKILL.md, раздел про докачку)',
              flush=True)
        return 1
    with open(OUT, 'wb') as f:
        for i in range(N):
            with open(f'{WORK}/p{i}', 'rb') as g:
                f.write(g.read())
    got = os.path.getsize(OUT)
    print(f'размер: {got}/{SIZE}', flush=True)
    if got != SIZE:
        return 1
    subprocess.run(['rm', '-rf', '/tmp/artx'], capture_output=True)
    os.makedirs('/tmp/artx', exist_ok=True)
    subprocess.run(['unzip', '-o', '-q', OUT, '-d', '/tmp/artx'])
    print('=== содержимое ===', flush=True)
    subprocess.run(['ls', '-la', '/tmp/artx'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
