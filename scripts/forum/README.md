# Архив темы 4PDA

Скачивание и разбор постов темы 1122662 в `docs/forum/`.

## Зачем так сложно

4PDA отдаёт **403** на любой прямой запрос (`requests`, `curl`) — стоит защита,
которая не обходится подстановкой User-Agent. Поэтому страницы снимает уже
авторизованный браузер, а скрипты только разбирают HTML.

Передать снятое из браузера на диск тоже непросто:

- `fetch`/`XHR` на `http://127.0.0.1` **не работает** — страница по https,
  приёмник по http, браузер режет это как mixed content (молча, по таймауту).
  `receiver.py` оставлен на случай, если запускать его из вкладки на http.
- Blob-скачивание больших файлов (>1 МБ) **не долетает** до `~/Downloads`.
  Одна страница (~210 КБ) проходит нормально.

Рабочий путь — снять страницы в память вкладки, ужать до текста постов и
скачать частями.

## Как пользоваться

### 1. Снять страницы

В консоли вкладки, открытой на теме (или через браузерный тул):

```js
// качаем все страницы темы в память вкладки
window.__grab = async (st) => (await fetch(
  '/forum/index.php?showtopic=1122662&st=' + st, {credentials:'include'}
)).text();

window.__pages = {};
for (let st = 0; st <= 1300; st += 20) {
  window.__pages[st] = await window.__grab(st);
  await new Promise(r => setTimeout(r, 400));   // не долбить форум
}
```

`st` растёт по 20 (постов на страницу). Верхнюю границу взять из номера
последнего поста: `st_max = floor(last_post / 20) * 20`.

### 2. Ужать до текста постов

```js
window.__slim = [];
Object.keys(window.__pages).map(Number).sort((a,b)=>a-b).forEach(k => {
  const d = new DOMParser().parseFromString(window.__pages[k], 'text/html');
  d.querySelectorAll('a[name^="entry"]').forEach(a => {
    const t = a.closest('table');
    if (t) window.__slim.push(a.getAttribute('name') + t.innerText);
  });
});
```

15 МБ HTML → ~1.9 МБ текста.

### 3. Скачать частями

```js
window.__dl = function(i, size) {
  const s = window.__slim.slice(i*size, (i+1)*size).join('\n\n@@@POST@@@\n\n');
  if (!s) return {done: true};
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([s], {type:'text/plain'}));
  a.download = '4pda_slim_' + String(i).padStart(2,'0') + '.txt';
  document.body.appendChild(a); a.click();
  setTimeout(() => a.remove(), 2000);
  return {i, kb: Math.round(s.length/1024)};
};
window.__dl(0, 200);   // затем 1, 2, … пока не вернёт {done:true}
```

### 4. Разобрать в файлы

```bash
python3 scripts/forum/parse_posts.py --out docs/forum --slim ~/Downloads/4pda_slim_*.txt
```

Для одной страницы, сохранённой целиком как HTML:

```bash
python3 scripts/forum/parse_posts.py --out docs/forum < page.html
```

## Что получается

```
docs/forum/
  INDEX.md          таблица: номер, автор, файл
  state.json        последний скачанный пост (last_num / last_entry)
  posts/
    01304.md        один пост = один файл
    01305.md
```

`state.json` держит номер последнего поста — по нему видно, с какого места
догружать в следующий раз. Повторный прогон той же страницы безопасен: файлы
перезаписываются по номеру поста.
