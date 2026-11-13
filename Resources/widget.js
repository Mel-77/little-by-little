/* Little by Little 桌面卡片：今天剩下的安排，点圆圈打勾 */
(function () {
  'use strict';

  const ENV = window.__DAYLINE_ENV__ || {};
  const COLORS = ['#F3C9B6', '#CFDFC4', '#C6D8E9', '#EBDCB2', '#DACCE7'];
  const WEEK = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
  const $ = (s) => document.querySelector(s);

  const pad = (n) => String(n).padStart(2, '0');
  const dateStr = (d) => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  const parseDate = (s) => {
    const p = s.split('-').map(Number);
    return new Date(p[0], p[1] - 1, p[2]);
  };
  const addDays = (s, n) => {
    const d = parseDate(s);
    d.setDate(d.getDate() + n);
    return dateStr(d);
  };
  const fmtHM = (m) => String(Math.floor(m / 60)) + ':' + pad(m % 60);

  let store = normalize(ENV.store || {});
  let lastHeight = 0;
  let today = ENV.date || dateStr(new Date());

  const nowMin = (() => {
    if (typeof ENV.now === 'string' && ENV.now.indexOf(':') > 0) {
      const p = ENV.now.split(':').map(Number);
      return p[0] * 60 + p[1];
    }
    const d = new Date();
    return d.getHours() * 60 + d.getMinutes();
  })();

  function normalize(src) {
    const out = { version: 1, blocks: [], habits: [] };
    (src.blocks || []).forEach((b) => {
      if (b && b.date) out.blocks.push(b);
    });
    (src.habits || []).forEach((h) => {
      if (h) out.habits.push(h);
    });
    return out;
  }

  function post(msg) {
    try {
      window.webkit.messageHandlers.lbl.postMessage(msg);
    } catch (e) {}
  }

  function save() {
    post({ cmd: 'save', store: store });
  }

  /// 让面板高度贴着内容走；字体加载完成、窗口尺寸变化时都要重测，
  /// 否则首次测到的是字体还没生效时的矮高度，卡片会被裁掉一截。
  function reportHeight() {
    window.requestAnimationFrame(function () {
      var card = document.getElementById('w');
      if (!card) return;
      // 卡片自己带 max-height: calc(100vh - 14px)：面板矮的时候量出来的是「被裁到面板高」，
      // 会把高度锁死在旧值里。量之前先摘掉上限，量完还回去。
      var prevMax = card.style.maxHeight;
      card.style.maxHeight = 'none';
      var h = Math.ceil(card.offsetHeight + 14);
      card.style.maxHeight = prevMax;
      if (Math.abs(h - lastHeight) > 2) {
        lastHeight = h;
        post({ cmd: 'widget-height', height: h });
      }
    });
  }

  function render() {
    const d = parseDate(today);
    $('#wDate').textContent = d.getMonth() + 1 + '月' + d.getDate() + '日';
    $('#wSub').textContent = WEEK[d.getDay()];

    const list = store.blocks
      .filter((b) => b.date === today)
      .sort((a, b) => (a.done === b.done ? a.start - b.start : a.done ? 1 : -1));

    const done = list.filter((b) => b.done).length;
    $('#wDone').textContent = done;
    $('#wTotal').textContent = list.length;
    $('#wBar').style.width = list.length ? Math.round((done / list.length) * 100) + '%' : '0%';

    const box = $('#wList');
    box.innerHTML = '';
    if (!list.length) {
      const empty = document.createElement('div');
      empty.className = 'w-empty';
      empty.innerHTML = '今天还空着。<br>打开 Little by Little，在时间轴上<b>拖一条</b>就行。';
      box.appendChild(empty);
    } else {
      list.forEach((b) => {
        const row = document.createElement('div');
        row.className = 'w-row' + (b.done ? ' done' : '');
        row.dataset.id = b.id;
        const running = !b.done && nowMin >= b.start && nowMin < b.start + b.dur;
        if (running) row.style.borderLeft = '2px solid ' + (COLORS[b.color % 5] || COLORS[0]);

        const check = document.createElement('button');
        check.className = 'w-check';
        check.textContent = '✓';
        check.title = b.done ? '标记未完成' : '完成';

        const time = document.createElement('span');
        time.className = 'w-time';
        time.textContent = fmtHM(b.start);

        const title = document.createElement('span');
        title.className = 'w-title';
        title.textContent = b.title || '（未命名）';

        row.appendChild(check);
        row.appendChild(time);
        row.appendChild(title);
        box.appendChild(row);
      });
    }

    $('#wFoot').textContent = list.length
      ? '还剩 ' + (list.length - done) + ' 件 · 点开 Little by Little'
      : '点开 Little by Little';

    reportHeight();
  }

  $('#wList').addEventListener('click', function (e) {
    const check = e.target.closest('.w-check');
    const row = e.target.closest('.w-row');
    if (!row) return;
    const b = store.blocks.find((x) => x.id === row.dataset.id);
    if (!b) return;
    if (check) {
      b.done = !b.done;
      render();
      save();
      return;
    }
    post({ cmd: 'show-main' });
  });

  $('#wFoot').addEventListener('click', () => post({ cmd: 'show-main' }));

  window.Little = {
    applyStore: function (next) {
      store = normalize(next || {});
      render();
    },
  };

  render();
  // 告诉外壳「鼠标进/出卡片」，外壳据此淡出/还原
  let hovering = false;
  document.addEventListener('mouseover', function () {
    if (hovering) return;
    hovering = true;
    post({ cmd: 'widget-hover', on: 1 });
  });
  document.addEventListener('mouseout', function (e) {
    if (e.relatedTarget) return;
    hovering = false;
    post({ cmd: 'widget-hover', on: 0 });
  });

  var cardEl = document.querySelector('.w');
  if (cardEl) post({ cmd: 'widget-hover', on: cardEl.matches(':hover') ? 1 : 0 });

  window.requestAnimationFrame(() => post({ cmd: 'rendered' }));
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(reportHeight);
  window.addEventListener('resize', reportHeight);
})();
