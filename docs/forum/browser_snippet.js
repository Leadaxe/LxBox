// Снятие темы 4PDA 1122662 из браузера. Выполнять в консоли на любой странице темы
// (нужна пройденная Cloudflare-проверка — поэтому и браузер, см. README.md).
//
// Порядок: __run() качает страницы → __build() собирает записи → __dlj() выгружает
// JSONL порциями. Дальше parse_posts.py --jsonl.

const TOPIC = 1122662;
const LAST_ST = 1300; // st последней страницы: (число постов − 1) / 20 * 20

// Форум отдаёт windows-1251. fetch().text() декодирует как UTF-8 и убивает
// кириллицу безвозвратно — читаем байты и декодируем явно.
window.__dec = new TextDecoder('windows-1251');
window.__pages = {};
window.__errs = [];

window.__grab = async function (st) {
  const r = await fetch(`/forum/index.php?showtopic=${TOPIC}&st=${st}`, {
    credentials: 'include',
  });
  if (!r.ok) throw new Error('status ' + r.status);
  return window.__dec.decode(await r.arrayBuffer());
};

// Качать пачками: за один вызов ~400 страниц упирается в таймаут отладчика.
window.__run = async function (from, to) {
  for (let st = from; st <= to; st += 20) {
    if (window.__pages[st]) continue;
    try {
      window.__pages[st] = await window.__grab(st);
    } catch (e) {
      window.__errs.push(st);
    }
    await new Promise((r) => setTimeout(r, 350));
  }
  return { done: Object.keys(window.__pages).length, errs: window.__errs.length };
};

// Поля берём из DOM, а не из innerText: тот склеивает абзацы и приклеивает к телу
// поста навигацию профиля.
window.__build = function () {
  window.__recs = [];
  Object.keys(window.__pages)
    .map(Number)
    .sort((a, b) => a - b)
    .forEach((k) => {
      const d = new DOMParser().parseFromString(window.__pages[k], 'text/html');
      d.querySelectorAll('a[name^="entry"]').forEach((a) => {
        const t = a.closest('table');
        if (!t) return;
        const txt = t.innerText;
        window.__recs.push({
          n: (txt.match(/Сообщение\s*#?(\d+)/) || [])[1] || '',
          a: ((t.querySelector('span.normalname a, b a, .postdetails a') || {}).textContent || '').trim(),
          d: (txt.match(/(Сегодня|Вчера|\d{2}\.\d{2}\.\d{2}),\s*\d{2}:\d{2}/) || [])[0] || '',
          e: a.getAttribute('name'),
          b: ((t.querySelector('.postcolor') || {}).innerText || '').trim(),
        });
      });
    });
  return window.__recs.length;
};

// Выгрузка порциями: один большой файл Chrome не отдаёт, а множественные загрузки
// требуют разрешения для сайта (значок в адресной строке).
window.__dlj = function (i, size = 200) {
  const part = window.__recs.slice(i * size, (i + 1) * size);
  if (!part.length) return { done: true };
  const s = part.map((r) => JSON.stringify(r)).join('\n');
  const blob = new Blob([new TextEncoder().encode(s)], {
    type: 'application/octet-stream',
  });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = '4pda_j' + String(i).padStart(2, '0') + '.jsonl';
  document.body.appendChild(a);
  a.click();
  a.remove();
  return { i, kb: Math.round(s.length / 1024) };
};

// --- порядок вызовов ---
// await window.__run(0, 420);
// await window.__run(440, 900);
// await window.__run(920, LAST_ST);
// window.__build();
// [0,1,2,3].map(i => window.__dlj(i));   // по 3-4 за раз
// [4,5,6].map(i => window.__dlj(i));
