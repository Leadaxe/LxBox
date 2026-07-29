#!/usr/bin/env python3
"""Локальный приёмник HTML-страниц темы, снятых браузером.

4PDA отдаёт 403 на прямые запросы, поэтому страницы качает уже авторизованный
браузер (fetch с credentials), а сюда шлёт POST'ом. Слушает только 127.0.0.1.

    python3 receiver.py --dir /tmp/4pda_raw --port 8777

Останавливается сам после --expect страниц (или по Ctrl-C).
"""

import argparse
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    outdir = "."
    expect = 0
    received = 0

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "content-type")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_POST(self):
        st = self.path.strip("/").split("/")[-1]
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        path = os.path.join(Handler.outdir, f"page_{int(st):05d}.html")
        with open(path, "wb") as f:
            f.write(body)

        Handler.received += 1
        print(f"  page st={st}: {len(body)} bytes  ({Handler.received}/{Handler.expect or '?'})")

        self.send_response(200)
        self._cors()
        self.end_headers()
        self.wfile.write(b"ok")

        if Handler.expect and Handler.received >= Handler.expect:
            print("получены все страницы, останавливаюсь")
            raise SystemExit(0)

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--expect", type=int, default=0)
    args = ap.parse_args()

    os.makedirs(args.dir, exist_ok=True)
    Handler.outdir = args.dir
    Handler.expect = args.expect

    print(f"слушаю 127.0.0.1:{args.port} → {args.dir}")
    try:
        HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
    except SystemExit:
        pass
    except KeyboardInterrupt:
        print("\nостановлен вручную")


if __name__ == "__main__":
    main()
