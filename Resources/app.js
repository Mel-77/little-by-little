/* Little by Little 主窗口逻辑
   坐标：顶部 = 00:00，1 分钟 = PPM 像素，拖动吸附 15 分钟。 */
(function () {
  'use strict';

  const ENV = window.__DAYLINE_ENV__ || {};
  const PPM = 1.15;
  const TOP = 16;
  const SNAP = 15;
  const MIN_DUR = 15;
  const DAY = 1440;
  const COLORS = ['#F3C9B6', '#CFDFC4', '#C6D8E9', '#EBDCB2', '#DACCE7'];
  const PREFER_WINDOW = {
    any: [8 * 60, 22 * 60],
    morning: [7 * 60, 12 * 60],
    afternoon: [13 * 60, 18 * 60],
    evening: [19 * 60, 22 * 60 + 30],
  };
  const WEEK = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
  const $ = (sel, root) => (root || document).querySelector(sel);

  /* ---------------- 小工具 ---------------- */
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
  const todayStr = () => dateStr(new Date());
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const snap = (m) => Math.round(m / SNAP) * SNAP;
  const fmtHM = (m) => {
    m = clamp(Math.round(m), 0, DAY);
    return (m >= DAY ? '24' : String(Math.floor(m / 60))) + ':' + pad(m % 60);
  };
  const durLabel = (min) => {
    if (min % 60 === 0) return min / 60 + ' 小时';
    if (min > 60) return (min / 60).toFixed(1).replace('.0', '') + ' 小时';
    return min + ' 分钟';
  };
  const uid = () =>
    (window.crypto && crypto.randomUUID)
      ? crypto.randomUUID()
      : 'b' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  const escapeHtml = (s) =>
    String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const el = (tag, cls, html) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html != null) n.innerHTML = html;
    return n;
  };

  /* ---------------- 状态 ---------------- */
  let store = normalize(ENV.store || {});
  let viewDate = ENV.date || todayStr();
  let selectedId = null;
  let editingId = null;
  let followToday = true;   // 停在「今天」时，跨过午夜要自动翻到新的一天
  let committing = false;
  let keepEmptyOnCommit = false;
  let toastTimer = 0;

  // 截图/测试时可以固定一个时刻，平时每次现算（窗口一直开着也会自己走）
  const pinnedNow = (() => {
    if (typeof ENV.now === 'string' && ENV.now.indexOf(':') > 0) {
      const p = ENV.now.split(':').map(Number);
      return p[0] * 60 + p[1];
    }
    return null;
  })();

  function nowMinute() {
    if (pinnedNow !== null) return pinnedNow;
    const d = new Date();
    return d.getHours() * 60 + d.getMinutes();
  }

  function normalize(src) {
    const out = { version: 1, blocks: [], habits: [] };
    (src.blocks || []).forEach((b) => {
      if (!b || !b.date) return;
      out.blocks.push({
        id: b.id || uid(),
        date: b.date,
        start: clamp(Number(b.start) || 0, 0, DAY - MIN_DUR),
        dur: clamp(Number(b.dur) || 60, MIN_DUR, DAY),
        title: typeof b.title === 'string' ? b.title : '',
        note: typeof b.note === 'string' ? b.note : '',
        done: !!b.done,
        color: clamp(Number(b.color) || 0, 0, 4),
        habitId: b.habitId || null,
        src: typeof b.src === 'string' ? b.src : null,
        hash: typeof b.hash === 'string' ? b.hash : null,
      });
    });
    (src.habits || []).forEach((h) => {
      if (!h) return;
      out.habits.push({
        id: h.id || uid(),
        title: typeof h.title === 'string' ? h.title : '新习惯',
        minutes: clamp(Number(h.minutes) || 60, 5, 600),
        period: h.period === 'month' ? 'month' : 'week',
        target: clamp(Number(h.target) || 1, 1, 31),
        prefer: PREFER_WINDOW[h.prefer] ? h.prefer : 'any',
        color: clamp(Number(h.color) || 0, 0, 4),
        createdAt: h.createdAt || new Date().toISOString(),
      });
    });
    return out;
  }

  /* ---------------- DOM ---------------- */
  const tlEl = $('#tl');
  const hoursEl = $('#hours');
  const gridEl = $('#grid');
  const blocksEl = $('#blocks');
  const nowEl = $('#nowline');
  const nowLabel = $('#nowLabel');
  const ghostEl = $('#ghost');
  const ghostLabel = $('#ghostLabel');
  const wrapEl = $('#timelineWrap');
  const habitsEl = $('#habits');
  const modal = $('#modal');
  const form = $('#habitForm');

  let editingHabitId = null;
  let formColor = 0;

  /* ---------------- 基础计算 ---------------- */
  const toMin = (y) => (y - TOP) / PPM;
  const toY = (m) => TOP + m * PPM;
  const blocksOf = (date) => store.blocks.filter((b) => b.date === date);
  const blockById = (id) => store.blocks.find((b) => b.id === id);

  function periodRange(period, refStr) {
    const d = parseDate(refStr);
    if (period === 'month') {
      return {
        start: dateStr(new Date(d.getFullYear(), d.getMonth(), 1)),
        end: dateStr(new Date(d.getFullYear(), d.getMonth() + 1, 0)),
      };
    }
    const dow = (d.getDay() + 6) % 7;
    const mon = addDays(refStr, -dow);
    return { start: mon, end: addDays(mon, 6) };
  }

  function habitProgress(h, refStr) {
    const r = periodRange(h.period, refStr);
    const done = store.blocks.filter(
      (b) => b.habitId === h.id && b.done && b.date >= r.start && b.date <= r.end
    ).length;
    return { done: done, target: h.target };
  }

  /* ---------------- 网格 ---------------- */
  function buildGrid() {
    hoursEl.innerHTML = '';
    gridEl.innerHTML = '';
    tlEl.style.height = toY(DAY) + 40 + 'px';
    for (let h = 0; h <= 24; h++) {
      const y = toY(h * 60);
      const label = el('div', 'hour-label' + (h % 3 === 0 ? ' major' : ''), h === 24 ? '24:00' : h + ':00');
      label.style.top = y + 'px';
      hoursEl.appendChild(label);
      if (h < 24) {
        const line = el('div', 'hour-line' + (h % 3 === 0 ? ' major' : ''));
        line.style.top = y + 'px';
        gridEl.appendChild(line);
        const half = el('div', 'half-line');
        half.style.top = y + 30 * PPM + 'px';
        gridEl.appendChild(half);
      }
    }
  }

  /* ---------------- 布局：同一时段并排 ---------------- */
  function layout(list) {
    const sorted = list.slice().sort((a, b) => a.start - b.start || a.dur - b.dur);
    const out = [];
    let cluster = [];
    let end = 0;

    const flush = () => {
      if (!cluster.length) return;
      const lanes = Math.max.apply(null, cluster.map((c) => c.lane)) + 1;
      cluster.forEach((c) => {
        c._w = 100 / lanes;
        c._x = c.lane * c._w;
        out.push(c);
      });
      cluster = [];
      end = 0;
    };

    sorted.forEach((b) => {
      if (cluster.length && b.start >= end) flush();
      const used = cluster.filter((c) => c.start + c.dur > b.start).map((c) => c.lane);
      let lane = 0;
      while (used.indexOf(lane) >= 0) lane++;
      const item = Object.assign({}, b, { lane: lane });
      cluster.push(item);
      end = Math.max(end, b.start + b.dur);
    });
    flush();
    return out;
  }

  /* ---------------- 渲染 ---------------- */
  function renderAll() {
    renderHeader();
    renderBlocks();
    renderHabits();
  }

  function renderHeader() {
    const d = parseDate(viewDate);
    $('#dateBig').textContent = d.getMonth() + 1 + '月' + d.getDate() + '日';
    $('#dateSub').textContent = WEEK[d.getDay()];

    const list = blocksOf(viewDate);
    const done = list.filter((b) => b.done).length;
    $('#statDone').textContent = done;
    $('#statTotal').textContent = list.length;
    $('#stat').hidden = list.length === 0;

    const today = todayStr();
    let rel = '';
    if (viewDate === today) rel = '今天';
    else if (viewDate === addDays(today, 1)) rel = '明天';
    else if (viewDate === addDays(today, -1)) rel = '昨天';
    else {
      const diff = Math.round((parseDate(viewDate) - parseDate(today)) / 86400000);
      rel = diff > 0 ? diff + ' 天后' : Math.abs(diff) + ' 天前';
    }
    const left = list.filter((b) => !b.done).length;
    $('#tlEmpty').hidden = list.length > 0;
    $('#dateNote').textContent = list.length
      ? rel + ' · 还剩 ' + left + ' 件'
      : rel + ' · 还空着';
    $('#todayBtn').style.opacity = viewDate === today ? '.45' : '1';
  }

  function titleNode(b) {
    if (editingId === b.id) {
      const input = el('input', 'b-input');
      input.value = b.title;
      input.maxLength = 60;
      input.placeholder = '写点什么…';
      input.addEventListener('keydown', onEditKey);
      input.addEventListener('blur', () => commitEdit(true));
      return input;
    }
    const title = el('span', 'b-title');
    if (b.title) title.textContent = b.title;
    else {
      title.classList.add('b-placeholder');
      title.textContent = '写点什么…';
    }
    return title;
  }

  function renderBlocks() {
    const placed = layout(blocksOf(viewDate));
    blocksEl.innerHTML = '';

    placed.forEach((b) => blocksEl.appendChild(blockNode(b)));
    renderNow();
    if (editingId) focusEditor();
  }

  function blockNode(b) {
    const height = Math.max(b.dur * PPM - 3, 20);
    const node = el('div', 'block');
    node.dataset.id = b.id;
    if (height < 46) node.classList.add('compact');
    if (height > 64) node.classList.add('tall');
    if (b.done) node.classList.add('done');
    if (selectedId === b.id) node.classList.add('selected');
    node.style.top = toY(b.start) + 'px';
    node.style.height = height + 'px';
    node.style.left = 'calc(' + b._x + '% + 2px)';
    node.style.width = 'calc(' + b._w + '% - 5px)';
    node.style.background = COLORS[b.color % COLORS.length];

    const checkBtn = el('button', 'b-check', '✓');
    checkBtn.title = b.done ? '标记未完成' : '完成';

    if (height < 46) {
      // 太矮：压成一行「7:00 事项 ✓」
      const row = el('div', 'b-row');
      row.appendChild(el('span', 'b-time', fmtHM(b.start)));
      row.appendChild(titleNode(b));
      const miniEdit = el('button', 'b-edit', '✎');
      miniEdit.title = '备注 / 改时间';
      row.appendChild(miniEdit);
      row.appendChild(checkBtn);
      node.appendChild(row);
      node.title = fmtHM(b.start) + ' – ' + fmtHM(b.start + b.dur);
    } else {
      const head = el('div', 'b-head');
      head.innerHTML = '<span class="b-time">' + fmtHM(b.start) + ' – ' + fmtHM(b.start + b.dur) + '</span>';
      const editBtn = el('button', 'b-edit', '✎');
      editBtn.title = '备注 / 改时间';
      head.appendChild(editBtn);
      head.appendChild(checkBtn);
      node.appendChild(head);
      node.appendChild(titleNode(b));
      if (b.note && height >= 62) {
        const note = el('div', 'b-note' + (height < 104 ? ' one-line' : ''));
        note.textContent = b.note;
        node.appendChild(note);
      }
    }
    if (b.note && height < 62) {
      const dot = el('span', 'b-note-dot', '·');
      dot.title = b.note;
      node.appendChild(dot);
    }

    node.appendChild(el('div', 'b-edge top')).dataset.edge = 'top';
    node.appendChild(el('div', 'b-edge bottom')).dataset.edge = 'bottom';
    return node;
  }

  function renderNow() {
    const isToday = viewDate === todayStr();
    if (!isToday) {
      nowEl.hidden = true;
      return;
    }
    nowEl.hidden = false;
    const m = nowMinute();
    nowEl.style.top = toY(m) + 'px';
    nowLabel.textContent = fmtHM(m);
    // 整点那一行本来就印着钟点数字。两个时间叠在一起会糊成一团，
    // 所以靠得太近时把「现在」往下（或往上）让开一点点，两边都还看得清。
    const hourMin = Math.round(m / 60) * 60;
    const gap = Math.abs(m - hourMin) * PPM;
    const need = 15;
    const off = gap < need ? (m < hourMin ? -1 : 1) * (need - gap + 2) : 0;
    nowLabel.style.transform = 'translateY(calc(-50% + ' + off.toFixed(1) + 'px))';
  }

  function renderHabits() {
    habitsEl.innerHTML = '';
    const habits = store.habits.slice().sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));
    if (!habits.length) {
      habitsEl.appendChild(
        el('div', 'side-tip', '还没有定期任务。<br>点右上角 ＋ 加一个：一周做几次、一次多久。')
      );
      return;
    }
    habits.forEach((h) => habitsEl.appendChild(habitNode(h)));
  }

  function habitNode(h) {
    const p = habitProgress(h, viewDate);
    const placed = store.blocks.find((b) => b.habitId === h.id && b.date === viewDate);
    const node = el('div', 'habit');
    node.dataset.id = h.id;
    node.style.setProperty('--hcolor', COLORS[h.color % COLORS.length]);

    const top = el('div', 'h-top');
    top.innerHTML =
      '<span class="h-dot" style="background:' + COLORS[h.color % COLORS.length] + '"></span>' +
      '<span class="h-title">' + escapeHtml(h.title) + '</span>' +
      '<span class="h-count"><b>' + p.done + '</b>/' + p.target + '</span>';
    node.appendChild(top);

    const ticks = el('div', 'ticks');
    const count = Math.min(p.target, 14);
    for (let i = 0; i < count; i++) {
      ticks.appendChild(el('i', 'tick' + (i < p.done ? ' on' : '')));
    }
    node.appendChild(ticks);

    const meta = el('div', 'h-meta');
    meta.innerHTML =
      '<span>' + (h.period === 'week' ? '每周 ' : '每月 ') + p.target + ' 次 · 每次 ' + durLabel(h.minutes) + '</span>';
    const btn = el('button', 'h-add');
    btn.dataset.add = h.id;
    if (placed) {
      btn.classList.add('is-placed');
      btn.textContent = placed.done ? '再来一次' : '已排 ' + fmtHM(placed.start);
    } else {
      btn.textContent = '排到这天';
    }
    meta.appendChild(btn);
    node.appendChild(meta);
    return node;
  }

  /* ---------------- 保存 ---------------- */
  function save() {
    renderHeader();
    window.webkit.messageHandlers.lbl.postMessage({ cmd: 'save', store: store });
  }

  function post(msg) {
    try {
      window.webkit.messageHandlers.lbl.postMessage(msg);
    } catch (e) {
      /* 浏览器里预览时忽略 */
    }
  }

  /* ---------------- 选中 / 编辑 ---------------- */
  function select(id) {
    selectedId = id;
    Array.prototype.forEach.call(blocksEl.children, (n) => {
      if (n.classList) n.classList.toggle('selected', n.dataset.id === id);
    });
  }

  function beginEdit(id) {
    editingId = id;
    selectedId = id;
    renderBlocks();
  }

  function focusEditor() {
    const input = blocksEl.querySelector('.b-input');
    if (!input) return;
    requestAnimationFrame(() => {
      if (document.activeElement !== input) {
        input.focus();
        input.select();
      }
    });
  }

  function onEditKey(e) {
    if (e.key === 'Enter') {
      e.preventDefault();
      commitEdit(true);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      // 取消：还没写名字的块直接收掉，别留空壳
      const b = blockById(editingId);
      if (b && !b.title) {
        store.blocks = store.blocks.filter((x) => x.id !== b.id);
        if (selectedId === b.id) selectedId = null;
        save();
      }
      editingId = null;
      renderBlocks();
      renderHeader();
    }
    e.stopPropagation();
  }

  function commitEdit(render) {
    if (committing) return;
    const input = blocksEl.querySelector('.b-input');
    if (!input) {
      editingId = null;
      return;
    }
    const id = editingId;
    const b = blockById(id);
    committing = true;
    if (b) {
      b.title = input.value.trim();
      if (!b.title && !keepEmptyOnCommit) {
        // 名字留空又没有在调时间，就当没写成，收掉，免得时间轴上堆空壳
        store.blocks = store.blocks.filter((x) => x.id !== b.id);
        if (selectedId === b.id) selectedId = null;
      }
    }
    editingId = null;
    committing = false;
    if (render !== false) renderBlocks();
    renderHeader();
    save();
  }

  /* ---------------- 交互 ---------------- */
  let gesture = null;

  blocksEl.addEventListener('pointerdown', function (e) {
    if (e.button !== 0) return;
    const check = e.target.closest('.b-check');
    if (check) {
      e.preventDefault();
      const node = check.closest('.block');
      const b = blockById(node.dataset.id);
      if (b) {
        b.done = !b.done;
        renderBlocks();
        renderHeader();
        save();
      }
      return;
    }

    // ✎（备注 / 改时间）：直接开详情，不要进拖拽手势——
    // 拖拽会 preventDefault + setPointerCapture，把按钮的 click 吞掉
    const editHit = e.target.closest ? e.target.closest('.b-edit') : null;
    if (editHit) {
      e.preventDefault();
      const host = editHit.closest('.block');
      if (host) openBlockModal(host.dataset.id);
      return;
    }

    let node = e.target.closest('.block');
    if (node && !blocksEl.contains(node)) node = null;
    const edgeFromTarget = e.target.dataset ? e.target.dataset.edge || null : null;

    if (editingId) {
      const active = blocksEl.querySelector('.b-input');
      if (active && active === e.target) return;
      // 手上正拿着这个块（要调时间），就别把它当“没写名字的空壳”收掉
      const heldId = node ? node.dataset.id : null;
      keepEmptyOnCommit = !!heldId;
      commitEdit(true);
      keepEmptyOnCommit = false;
      if (heldId) {
        node = blocksEl.querySelector('.block[data-id="' + heldId + '"]');
        if (!node) return;
      }
    }

    const rect = blocksEl.getBoundingClientRect();
    const y = e.clientY - rect.top;
    const rawMin = toMin(y);

    if (node) {
      e.preventDefault();
      const b = blockById(node.dataset.id);
      if (!b) return;
      select(b.id);
      const edge = edgeFromTarget || (e.target.dataset ? e.target.dataset.edge : null);
      gesture = {
        mode: edge ? 'resize-' + edge : 'move',
        id: b.id,
        node: node,
        startY: e.clientY,
        startX: e.clientX,
        origStart: b.start,
        origDur: b.dur,
        moved: false,
      };
      node.classList.add('dragging');
      try { blocksEl.setPointerCapture(e.pointerId); } catch (err) {}
      return;
    }

    e.preventDefault();
    select(null);
    const startMin = clamp(snap(rawMin), 0, DAY);
    gesture = {
      mode: 'create',
      startY: e.clientY,
      anchor: startMin,
      current: startMin,
      moved: false,
      pointerId: e.pointerId,
    };
    try { blocksEl.setPointerCapture(e.pointerId); } catch (err) {}
    ghostEl.hidden = false;
    updateGhost(startMin, startMin + MIN_DUR);
  });

  blocksEl.addEventListener('pointermove', function (e) {
    if (!gesture) return;
    const rect = blocksEl.getBoundingClientRect();
    const dyMin = (e.clientY - gesture.startY) / PPM;

    if (gesture.mode === 'create') {
      const raw = toMin(e.clientY - rect.top);
      gesture.current = clamp(snap(raw), 0, DAY);
      if (Math.abs(e.clientY - gesture.startY) > 4 || Math.abs(gesture.current - gesture.anchor) >= SNAP) {
        gesture.moved = true;
      }
      const a = Math.min(gesture.anchor, gesture.current);
      const b = Math.max(gesture.anchor, gesture.current);
      updateGhost(a, Math.max(b, a + MIN_DUR));
      autoScroll(e.clientY);
      return;
    }

    const b = blockById(gesture.id);
    if (!b) return;
    if (Math.hypot(e.clientX - gesture.startX, e.clientY - gesture.startY) > 4) gesture.moved = true;

    if (gesture.mode === 'move') {
      gesture.deletePending = e.clientX < rect.left - 24 || e.clientX > rect.right + 24;
      gesture.node.classList.toggle('delete-pending', gesture.deletePending);
      if (gesture.deletePending) return;
      const delta = snap(dyMin);
      b.start = clamp(gesture.origStart + delta, 0, DAY - gesture.origDur);
    } else if (gesture.mode === 'resize-top') {
      const newStart = clamp(snap(gesture.origStart + dyMin), 0, gesture.origStart + gesture.origDur - MIN_DUR);
      b.start = newStart;
      b.dur = gesture.origStart + gesture.origDur - newStart;
    } else if (gesture.mode === 'resize-bottom') {
      const end = clamp(snap(gesture.origStart + gesture.origDur + dyMin), b.start + MIN_DUR, DAY);
      b.dur = end - b.start;
    }
    paintDuringGesture(b);
    autoScroll(e.clientY);
  });

  function paintDuringGesture(b) {
    if (!gesture || !gesture.node) return;
    const node = gesture.node;
    node.style.top = toY(b.start) + 'px';
    node.style.height = Math.max(b.dur * PPM - 3, 20) + 'px';
    const t = node.querySelector('.b-time');
    if (t) t.textContent = fmtHM(b.start) + ' – ' + fmtHM(b.start + b.dur);
  }

  function updateGhost(a, b) {
    ghostEl.style.top = toY(a) + 'px';
    ghostEl.style.height = Math.max((b - a) * PPM - 2, MIN_DUR * PPM - 2) + 'px';
    ghostLabel.textContent = fmtHM(a) + ' – ' + fmtHM(b);
  }

  function autoScroll(clientY) {
    const r = wrapEl.getBoundingClientRect();
    const edge = 46;
    if (clientY < r.top + edge) wrapEl.scrollTop -= 14;
    else if (clientY > r.bottom - edge) wrapEl.scrollTop += 14;
  }

  window.addEventListener('pointerup', function (e) {
    if (!gesture) return;
    const g = gesture;
    gesture = null;
    ghostEl.hidden = true;

    if (g.mode === 'create') {
      if (g.moved) {
        const a = Math.min(g.anchor, g.current);
        const b = Math.max(g.anchor, g.current);
        const dur = Math.max(b - a, MIN_DUR);
        createBlock(g.anchor <= g.current ? a : b - dur, dur);
      } else {
        createBlock(g.anchor, 60);
      }
      return;
    }

    if (g.node) g.node.classList.remove('dragging');
    const b = blockById(g.id);
    if (!b) return;
    if (g.mode === 'move' && g.moved) {
      const rect = blocksEl.getBoundingClientRect();
      if (e.clientX < rect.left - 24 || e.clientX > rect.right + 24) {
        deleteBlock(g.id);
        return;
      }
    }
    if (!g.moved) {
      return;
    }
    renderBlocks();
    renderHeader();
    save();
  });

  window.addEventListener('pointercancel', function () {
    if (!gesture) return;
    const b = blockById(gesture.id);
    if (b) { b.start = gesture.origStart; b.dur = gesture.origDur; }
    gesture = null;
    ghostEl.hidden = true;
    renderBlocks();
  });

  function createBlock(start, dur) {
    const b = {
      id: uid(),
      date: viewDate,
      start: clamp(snap(start), 0, DAY - MIN_DUR),
      dur: clamp(dur, MIN_DUR, DAY),
      title: '',
      done: false,
      color: 0,
      habitId: null,
    };
    b.start = clamp(b.start, 0, DAY - b.dur);
    store.blocks.push(b);
    selectedId = b.id;
    editingId = b.id;
    renderAll();
    save();
    requestAnimationFrame(() => {
      const node = blocksEl.querySelector('.block[data-id="' + b.id + '"]');
      if (node) {
        const top = node.offsetTop;
        if (top < wrapEl.scrollTop + 40 || top > wrapEl.scrollTop + wrapEl.clientHeight - 80) {
          wrapEl.scrollTo({ top: Math.max(0, top - 160), behavior: 'smooth' });
        }
      }
    });
  }

  function deleteBlock(id) {
    store.blocks = store.blocks.filter((b) => b.id !== id);
    if (editingId === id) editingId = null;
    if (selectedId === id) selectedId = null;
    renderAll();
    save();
  }

  /* 双击改名 */
  blocksEl.addEventListener('dblclick', function (e) {
    const node = e.target.closest('.block');
    if (!node) return;
    if (e.target.classList.contains('b-check') || e.target.closest('.b-edit')) return;
    if (e.target.classList.contains('b-note')) {
      openBlockModal(node.dataset.id);
      return;
    }
    beginEdit(node.dataset.id);
  });

  /* 右键 / ✎ → 打开详情（备注、改时间、改颜色、删除） */
  blocksEl.addEventListener('contextmenu', function (e) {
    const node = e.target.closest('.block');
    e.preventDefault();
    if (!node) return;
    openBlockModal(node.dataset.id);
  });

  blocksEl.addEventListener('click', function (e) {
    const btn = e.target.closest('.b-edit');
    if (!btn) return;
    const node = btn.closest('.block');
    if (!node) return;
    e.stopPropagation();
    openBlockModal(node.dataset.id);
  });

  /* 键盘 */
  document.addEventListener('keydown', function (e) {
    if (editingId) return;
    if (modal.hidden === false) return;
    if (blockModal.hidden === false) return;
    if (sumModal.hidden === false) return;
    if (bulkModal.hidden === false) {
      if (e.key === 'Escape') closeBulk();
      return;
    }
    if ((e.key === 'Backspace' || e.key === 'Delete') && selectedId) {
      e.preventDefault();
      deleteBlock(selectedId);
    }
    if (e.key === 'Enter' && selectedId) {
      e.preventDefault();
      beginEdit(selectedId);
    }
    if (e.key === 'Escape') {
      select(null);
      selectedId = null;
    }
  });

  /* ---------------- 导航 ---------------- */
  function goDate(target) {
    viewDate = target;
    followToday = target === todayStr();
    selectedId = null;
    editingId = null;
    renderAll();
    scrollToNow();
  }
  $('#prevDay').addEventListener('click', () => goDate(addDays(viewDate, -1)));
  $('#nextDay').addEventListener('click', () => goDate(addDays(viewDate, 1)));
  $('#todayBtn').addEventListener('click', () => goDate(todayStr()));

  function scrollToNow() {
    const anchor = viewDate === todayStr() ? nowMinute() : 9 * 60;
    wrapEl.scrollTop = Math.max(0, toY(anchor) - 170);
  }

  /* ---------------- 定期任务：一键排入 ---------------- */
  habitsEl.addEventListener('click', function (e) {
    const addBtn = e.target.closest('.h-add');
    if (addBtn) {
      const h = store.habits.find((x) => x.id === addBtn.dataset.add);
      if (!h) return;
      placeHabit(h);
      return;
    }
    const card = e.target.closest('.habit');
    if (card) openHabitModal(store.habits.find((x) => x.id === card.dataset.id));
  });

  function findSlot(date, dur, win) {
    const list = blocksOf(date).slice().sort((a, b) => a.start - b.start);
    let cursor = win[0];
    for (let i = 0; i < list.length; i++) {
      const b = list[i];
      const bs = b.start;
      const be = b.start + b.dur;
      if (be <= cursor) continue;
      if (bs >= win[1]) break;
      if (bs - cursor >= dur && bs >= win[0]) return cursor;
      cursor = Math.max(cursor, be);
      if (cursor + dur > win[1]) break;
    }
    if (win[1] - cursor >= dur) return cursor;
    return null;
  }

  function placeHabit(h) {
    const win = PREFER_WINDOW[h.prefer] || PREFER_WINDOW.any;
    const dur = clamp(h.minutes, MIN_DUR, DAY);
    let start = findSlot(viewDate, dur, win);
    if (start == null) {
      const list = blocksOf(viewDate);
      const lastEnd = list.length ? Math.max.apply(null, list.map((b) => b.start + b.dur)) : 0;
      start = clamp(lastEnd, win[0], Math.max(win[0], DAY - dur));
      toast('白天塞不下了，先放到 ' + fmtHM(start));
    } else {
      toast('排到 ' + fmtHM(start) + '，一次 ' + durLabel(dur));
    }

    const b = {
      id: uid(),
      date: viewDate,
      start: start,
      dur: dur,
      title: h.title,
      done: false,
      color: h.color,
      habitId: h.id,
    };
    store.blocks.push(b);
    selectedId = b.id;
    editingId = null;
    renderAll();
    save();
    requestAnimationFrame(() => {
      const node = blocksEl.querySelector('.block[data-id="' + b.id + '"]');
      if (node) {
        const top = node.offsetTop;
        wrapEl.scrollTo({ top: Math.max(0, top - 160), behavior: 'smooth' });
      }
    });
  }

  /* ---------------- 弹窗 ---------------- */
  function openHabitModal(habit) {
    editingHabitId = habit ? habit.id : null;
    $('#modalTitle').textContent = habit ? '编辑定期任务' : '新增定期任务';
    $('#hName').value = habit ? habit.title : '';
    $('#hMin').value = habit ? habit.minutes : 60;
    $('#hTarget').value = habit ? habit.target : 3;
    formColor = habit ? habit.color : 0;

    updateChips($('#durChips'), '[data-min]', habit ? String(habit.minutes) : '60', 'data-min');
    updateSeg($('#periodSeg'), habit ? habit.period : 'week', 'data-period');
    updateSeg($('#preferSeg'), habit ? habit.prefer : 'any', 'data-prefer');
    renderSwatches();

    $('#hDelete').hidden = !habit;
    modal.hidden = false;
    setTimeout(() => $('#hName').focus(), 60);
  }

  function closeHabitModal() {
    modal.hidden = true;
    editingHabitId = null;
  }

  function updateChips(root, sel, value) {
    Array.prototype.forEach.call(root.querySelectorAll(sel), (c) => {
      c.classList.toggle('is-on', c.getAttribute('data-min') === value);
    });
  }

  function updateSeg(root, value, attr) {
    Array.prototype.forEach.call(root.querySelectorAll('.seg-btn'), (c) => {
      c.classList.toggle('is-on', c.getAttribute(attr) === value);
    });
  }

  function renderSwatches() {
    const box = $('#swatches');
    box.innerHTML = '';
    COLORS.forEach((c, i) => {
      const b = el('button', 'swatch' + (i === formColor ? ' is-on' : ''));
      b.type = 'button';
      b.style.background = c;
      b.dataset.color = i;
      b.addEventListener('click', () => {
        formColor = i;
        renderSwatches();
      });
      box.appendChild(b);
    });
  }

  $('#durChips').addEventListener('click', (e) => {
    const chip = e.target.closest('.chip');
    if (!chip) return;
    $('#hMin').value = chip.dataset.min;
    updateChips($('#durChips'), '[data-min]', chip.dataset.min);
  });

  $('#hMin').addEventListener('input', () => {
    updateChips($('#durChips'), '[data-min]', $('#hMin').value);
  });

  $('#periodSeg').addEventListener('click', (e) => {
    const b = e.target.closest('.seg-btn');
    if (!b) return;
    updateSeg($('#periodSeg'), b.dataset.period, 'data-period');
    $('#hTarget').max = b.dataset.period === 'month' ? 31 : 7;
  });

  $('#preferSeg').addEventListener('click', (e) => {
    const b = e.target.closest('.seg-btn');
    if (!b) return;
    updateSeg($('#preferSeg'), b.dataset.prefer, 'data-prefer');
  });

  $('#hCancel').addEventListener('click', closeHabitModal);
  modal.addEventListener('click', (e) => {
    if (e.target === modal) closeHabitModal();
  });

  $('#hDelete').addEventListener('click', () => {
    if (!editingHabitId) return;
    const h = store.habits.find((x) => x.id === editingHabitId);
    if (!h) return;
    if (!confirm('删掉定期任务「' + h.title + '」？已经排进日程的不会被删除。')) return;
    store.habits = store.habits.filter((x) => x.id !== h.id);
    store.blocks.forEach((b) => {
      if (b.habitId === h.id) b.habitId = null;
    });
    closeHabitModal();
    renderAll();
    save();
  });

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const name = $('#hName').value.trim();
    if (!name) {
      $('#hName').focus();
      return;
    }
    const minutes = clamp(Number($('#hMin').value) || 60, 5, 600);
    const period = $('#periodSeg .is-on').dataset.period;
    const target = clamp(Number($('#hTarget').value) || 1, 1, period === 'month' ? 31 : 7);
    const prefer = $('#preferSeg .is-on').dataset.prefer;

    if (editingHabitId) {
      const h = store.habits.find((x) => x.id === editingHabitId);
      if (h) {
        h.title = name;
        h.minutes = minutes;
        h.period = period;
        h.target = target;
        h.prefer = prefer;
        h.color = formColor;
      }
    } else {
      store.habits.push({
        id: uid(),
        title: name,
        minutes: minutes,
        period: period,
        target: target,
        prefer: prefer,
        color: formColor,
        createdAt: new Date().toISOString(),
      });
    }
    closeHabitModal();
    renderAll();
    save();
  });

  $('#addHabit').addEventListener('click', () => openHabitModal(null));

  /* ---------------- 单条事项：备注 / 时间 ---------------- */
  const blockModal = $('#blockModal');
  const sumModal = $('#sumModal');
  let editingBlockId = null;
  let blockColor = 0;

  function minutesToTime(m) {
    const v = clamp(Math.round(m), 0, DAY);
    return (v === DAY ? '24:00' : String(Math.floor(v / 60)).padStart(2, '0') + ':' + String(v % 60).padStart(2, '0'));
  }

  function timeToMinutes(v) {
    const p = String(v || '').split(':');
    if (p.length < 2) return null;
    const h = Number(p[0]);
    const m = Number(p[1]);
    if (isNaN(h) || isNaN(m)) return null;
    return clamp(h * 60 + m, 0, DAY);
  }

  function fmtDur(minutes) {
    const m = Math.max(0, Math.round(minutes));
    const h = Math.floor(m / 60);
    const r = m % 60;
    if (h && r) return h + ' 小时 ' + r + ' 分';
    if (h) return h + ' 小时';
    return r + ' 分';
  }

  function openBlockModal(id) {
    const b = blockById(id);
    if (!b) return;
    if (editingId) commitEdit(true);
    editingBlockId = id;
    blockColor = b.color;
    $('#bName').value = b.title;
    $('#bNote').value = b.note || '';
    $('#bStart').value = minutesToTime(b.start);
    $('#bEnd').value = minutesToTime(b.start + b.dur);
    renderBlockSwatches();
    updateDurHint();
    blockModal.hidden = false;
    setTimeout(() => $('#bName').focus(), 60);
  }

  function closeBlockModal() {
    blockModal.hidden = true;
    editingBlockId = null;
  }

  function updateDurHint() {
    const a = timeToMinutes($('#bStart').value);
    const b = timeToMinutes($('#bEnd').value);
    $('#bDurHint').textContent = a != null && b != null && b > a ? fmtDur(b - a) : '—';
  }

  function renderBlockSwatches() {
    const box = $('#bSwatches');
    box.innerHTML = '';
    COLORS.forEach((c, i) => {
      const btn = el('button', 'swatch' + (i === blockColor ? ' is-on' : ''));
      btn.type = 'button';
      btn.style.background = c;
      btn.dataset.color = i;
      btn.addEventListener('click', () => {
        blockColor = i;
        renderBlockSwatches();
      });
      box.appendChild(btn);
    });
  }

  $('#bStart').addEventListener('input', updateDurHint);
  $('#bEnd').addEventListener('input', updateDurHint);
  $('#bCancel').addEventListener('click', closeBlockModal);
  blockModal.addEventListener('click', (e) => {
    if (e.target === blockModal) closeBlockModal();
  });

  $('#bDelete').addEventListener('click', () => {
    const b = blockById(editingBlockId);
    if (!b) return;
    if (!confirm('删掉「' + (b.title || '这一条') + '」？')) return;
    closeBlockModal();
    deleteBlock(b.id);
  });

  $('#blockForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const b = blockById(editingBlockId);
    if (!b) return;
    const name = $('#bName').value.trim();
    let start = timeToMinutes($('#bStart').value);
    let end = timeToMinutes($('#bEnd').value);
    if (start == null) start = b.start;
    if (end == null) end = start + b.dur;
    if (end <= start) end = start + MIN_DUR;
    if (end > DAY) { end = DAY; start = Math.min(start, DAY - MIN_DUR); }
    b.title = name;
    b.note = $('#bNote').value.trim();
    b.start = start;
    b.dur = Math.max(MIN_DUR, end - start);
    b.color = blockColor;
    closeBlockModal();
    renderAll();
    save();
  });

  /* ---------------- 总结 ---------------- */
  let sumSpan = 'week';

  function spanRange(span) {
    const today = todayStr();
    if (span === 'year') {
      return { start: today.slice(0, 4) + '-01-01', end: today.slice(0, 4) + '-12-31' };
    }
    return periodRange(span === 'month' ? 'month' : 'week', today);
  }

  function summaryData(span) {
    const r = spanRange(span);
    const map = new Map();
    store.blocks.forEach((b) => {
      if (!b.done || b.date < r.start || b.date > r.end) return;
      const key = (b.title || '').trim() || '（未命名）';
      const g = map.get(key) || { title: key, minutes: 0, count: 0, color: b.color || 0 };
      g.minutes += b.dur;
      g.count += 1;
      map.set(key, g);
    });
    const rows = Array.from(map.values()).sort((a, b) => b.minutes - a.minutes || a.title.localeCompare(b.title));
    const total = rows.reduce((n, x) => n + x.minutes, 0);
    const count = rows.reduce((n, x) => n + x.count, 0);
    return { start: r.start, end: r.end, rows: rows, total: total, count: count };
  }

  function renderSummary() {
    const data = summaryData(sumSpan);
    const d1 = parseDate(data.start);
    const d2 = parseDate(data.end);
    const label = (d1.getMonth() + 1) + '月' + d1.getDate() + '日 – ' + (d2.getMonth() + 1) + '月' + d2.getDate() + '日';
    $('#sumRange').textContent = label;
    $('#sumTotal').innerHTML = data.count
      ? '一共 <b>' + fmtDur(data.total) + '</b> · ' + data.count + ' 件'
      : '这段时间还没有勾掉的事情';

    const box = $('#sumList');
    box.innerHTML = '';
    if (!data.rows.length) {
      box.appendChild(el('div', 'sum-empty', '做完的点一下勾，这里就会按名字把时间加起来。'));
      return;
    }
    const max = data.rows[0].minutes || 1;
    data.rows.forEach((row) => {
      const line = el('div', 'sum-row');
      const fill = el('i', 'sum-fill');
      fill.style.width = Math.max(6, Math.round((row.minutes / max) * 100)) + '%';
      fill.style.background = COLORS[row.color % COLORS.length];
      const name = el('span', 'sum-name', row.title);
      const meta = el('span', 'sum-meta', row.count + ' 次');
      const time = el('span', 'sum-time', fmtDur(row.minutes));
      line.appendChild(fill);
      line.appendChild(name);
      line.appendChild(meta);
      line.appendChild(time);
      box.appendChild(line);
    });
  }

  function openSummary() {
    sumModal.hidden = false;
    renderSummary();
  }

  function closeSummary() {
    sumModal.hidden = true;
  }

  $('#sumSeg').addEventListener('click', (e) => {
    const btn = e.target.closest('.seg-btn');
    if (!btn) return;
    sumSpan = btn.dataset.span;
    updateSeg($('#sumSeg'), sumSpan, 'data-span');
    renderSummary();
  });
  $('#sumBtn').addEventListener('click', openSummary);
  $('#sumClose').addEventListener('click', closeSummary);
  sumModal.addEventListener('click', (e) => {
    if (e.target === sumModal) closeSummary();
  });

  /* ---------------- 批量加：选几天 → 一个时间段 ---------------- */
  const bulkModal = $('#bulkModal');
  const bulkGrid = $('#bulkGrid');
  const bulkTitle = $('#bulkTitle');
  const bulkNote = $('#bulkNote');
  const bulkStart = $('#bulkStart');
  const bulkEnd = $('#bulkEnd');
  const bulkSum = $('#bulkSum');
  const bulkGo = $('#bulkGo');
  const bulkCount = $('#bulkCount');
  const bulkSel = new Set();
  let bulkMonth = todayStr().slice(0, 7);
  let bulkAnchor = null;
  let bulkPaint = null;
  let bulkColor = 1;

  const ymd = (y, m, d) => y + '-' + pad(m) + '-' + pad(d);
  const monthParts = (ym) => ym.split('-').map(Number);
  const dim = (y, m) => new Date(y, m, 0).getDate();
  const mondayIdx = (y, m, d) => (new Date(y, m - 1, d).getDay() + 6) % 7;
  const shortMD = (ds) => Number(ds.slice(5, 7)) + '/' + Number(ds.slice(8, 10));
  const weekdayOf = (ds) => (parseDate(ds).getDay() + 6) % 7 + 1;   // 1=周一 … 7=周日
  const bulkBlocks = (ds) => store.blocks.filter((b) => b.date === ds);

  function bulkSet(ds, on) {
    if (!ds || ds < todayStr()) return false;
    if (on) {
      if (bulkSel.has(ds)) return false;
      bulkSel.add(ds);
      return true;
    }
    if (!bulkSel.has(ds)) return false;
    bulkSel.delete(ds);
    return true;
  }

  function bulkTimes() {
    const a = timeToMinutes(bulkStart.value);
    const b = timeToMinutes(bulkEnd.value);
    return { a: a, b: b, dur: (a != null && b != null && b > a) ? b - a : 0 };
  }

  function renderBulkSum() {
    const t = bulkTimes();
    $('#bulkDur').textContent = t.dur ? durLabel(t.dur) : '—';
    const title = bulkTitle.value.trim();
    const days = Array.from(bulkSel).filter((d) => d >= todayStr()).sort();
    bulkGo.disabled = !(title && t.dur > 0 && days.length > 0);
    if (!days.length) {
      bulkSum.innerHTML = '<span class="bulk-empty">在左边点几天，这里会告诉你加几条。</span>';
      return;
    }
    let html;
    if (t.dur > 0) {
      html = '在 <b>' + days.length + '</b> 天各加一条 <b>' + fmtHM(t.a) + '–' + fmtHM(t.b) + '</b> ' +
        (title ? escapeHtml(title) : '<span class="bulk-empty">（还没写名字）</span>') +
        '，共 <b>' + days.length + '</b> 条。';
    } else {
      html = '在 <b>' + days.length + '</b> 天各加一条，共 <b>' + days.length + '</b> 条 —— 先定个时间段。';
    }
    html += '<span class="bulk-days">' + days.slice(0, 14).map(shortMD).join('、') +
      (days.length > 14 ? ' …' : '') + '</span>';
    if (t.dur > 0) {
      const hits = days.filter((ds) => bulkBlocks(ds).some((b) => b.start < t.a + t.dur && b.start + b.dur > t.a));
      if (days.indexOf(todayStr()) >= 0 && t.b <= nowMinute()) {
        html += '<span class="warn">今天这个时段已经过去了 —— 加进去会落在现在这条线上面，要的话回头删掉就行。</span>';
      }
      if (hits.length) {
        const names = hits.slice(0, 2).map((ds) => {
          const b = bulkBlocks(ds).find((x) => x.start < t.a + t.dur && x.start + x.dur > t.a);
          return shortMD(ds) + '「' + escapeHtml(b.title || '这条') + '」';
        });
        html += '<span class="warn">' + names.join('、') +
          (hits.length > 2 ? ' 等 ' + hits.length + ' 天' : '') +
          ' 那个时段已经有安排，会并排放在一起。</span>';
      }
    }
    bulkSum.innerHTML = html;
  }

  function renderBulkCal() {
    const p = monthParts(bulkMonth);
    const y = p[0], m = p[1];
    $('#bulkMonth').innerHTML = '<b>' + y + '</b> 年 <b>' + m + '</b> 月';
    const first = mondayIdx(y, m, 1);
    const total = dim(y, m);
    const prevTotal = dim(m === 1 ? y - 1 : y, m === 1 ? 12 : m - 1);
    const today = todayStr();
    let html = ['一', '二', '三', '四', '五', '六', '日']
      .map((w) => '<div class="bulk-wd">' + w + '</div>').join('');
    for (let i = first; i > 0; i--) html += '<div class="bulk-d pad">' + (prevTotal - i + 1) + '</div>';
    for (let d = 1; d <= total; d++) {
      const ds = ymd(y, m, d);
      const n = bulkBlocks(ds).length;
      html += '<div class="bulk-d' + (ds < today ? ' past' : '') + (ds === today ? ' today' : '') +
        (bulkSel.has(ds) ? ' sel' : '') + '" data-d="' + ds + '">' + d +
        (n ? '<span class="bulk-dots">' + new Array(Math.min(n, 3) + 1).join('<i></i>') + '</span>' : '') +
        '</div>';
    }
    const tail = (7 - ((first + total) % 7)) % 7;
    for (let i = 1; i <= tail; i++) html += '<div class="bulk-d pad">' + i + '</div>';
    bulkGrid.innerHTML = html;
    bulkCount.textContent = bulkSel.size;
    renderBulkSum();
  }

  function bulkRepaint() {
    bulkGrid.querySelectorAll('.bulk-d[data-d]').forEach((n) => n.classList.toggle('sel', bulkSel.has(n.dataset.d)));
    bulkCount.textContent = bulkSel.size;
    renderBulkSum();
  }

  function bulkFillRange(a, b, on) {
    const from = a < b ? a : b;
    const to = a < b ? b : a;
    let cur = from;
    while (cur <= to) {
      bulkSet(cur, on);
      cur = addDays(cur, 1);
    }
    bulkRepaint();
  }

  bulkGrid.addEventListener('mousedown', (e) => {
    const cell = e.target.closest ? e.target.closest('.bulk-d') : null;
    if (!cell || !cell.dataset.d) return;
    e.preventDefault();
    const ds = cell.dataset.d;
    if (ds < todayStr()) return;
    if (e.shiftKey && bulkAnchor) {
      bulkFillRange(bulkAnchor, ds, true);
      bulkPaint = null;
      return;
    }
    const on = !bulkSel.has(ds);
    bulkSet(ds, on);
    bulkAnchor = ds;
    bulkPaint = on;
    bulkRepaint();
  });

  bulkGrid.addEventListener('mouseover', (e) => {
    if (bulkPaint === null) return;
    const cell = e.target.closest ? e.target.closest('.bulk-d') : null;
    if (!cell || !cell.dataset.d) return;
    const ds = cell.dataset.d;
    if (bulkSet(ds, bulkPaint)) {
      bulkAnchor = ds;
      bulkRepaint();
    }
  });

  document.addEventListener('mouseup', () => { bulkPaint = null; });

  function bulkShiftMonth(delta) {
    const p = monthParts(bulkMonth);
    let yy = p[0], mm = p[1] + delta;
    if (mm < 1) { mm = 12; yy -= 1; }
    if (mm > 12) { mm = 1; yy += 1; }
    bulkMonth = yy + '-' + pad(mm);
    renderBulkCal();
  }

  function bulkAddDates(list) {
    list.forEach((ds) => bulkSet(ds, true));
    bulkRepaint();
  }

  $('#bulkPrev').addEventListener('click', () => bulkShiftMonth(-1));
  $('#bulkNext').addEventListener('click', () => bulkShiftMonth(1));
  $('#bulkToday').addEventListener('click', () => {
    bulkMonth = todayStr().slice(0, 7);
    renderBulkCal();
  });
  $('#bulkClear').addEventListener('click', () => {
    bulkSel.clear();
    bulkAnchor = null;
    renderBulkCal();
  });

  function bulkRangeInputs() {
    const from = ($('#bulkFrom').value || '').trim();
    const to = ($('#bulkTo').value || '').trim();
    if (!from && !to) return null;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to)) return 'bad';
    if (from > to) return 'bad';
    return [from, to];
  }

  // 快捷选择的作用范围：填了「从 / 到」就只在那段里挑，没填就按当前显示的这个月（从今天算起）
  function bulkScope() {
    const today = todayStr();
    const r = bulkRangeInputs();
    if (r === 'bad') return null;
    if (r) return [r[0] < today ? today : r[0], r[1]];
    const p = monthParts(bulkMonth);
    const firstDay = ymd(p[0], p[1], 1);
    return [firstDay > today ? firstDay : today, ymd(p[0], p[1], dim(p[0], p[1]))];
  }

  function bulkDaysBetween(from, to, keep) {
    const list = [];
    const today = todayStr();
    for (let ds = from; ds <= to; ds = addDays(ds, 1)) {
      if (ds < today) continue;
      if (!keep || keep(ds)) list.push(ds);
    }
    return list;
  }

  // 在这段里「重新决定」选哪些天：先清掉这段里已选的，再按 keep 选上（段外的不动）
  function bulkSelectWithin(from, to, keep) {
    const today = todayStr();
    const a = from < today ? today : from;
    for (let ds = a; ds <= to; ds = addDays(ds, 1)) bulkSel.delete(ds);
    const list = bulkDaysBetween(a, to, keep);
    list.forEach((ds) => bulkSel.add(ds));
    bulkMonth = a.slice(0, 7);
    return list;
  }

  function bulkQuick(keep, emptyTip) {
    const r = bulkRangeInputs();
    if (r === 'bad') {
      toast('「从 / 到」没填对，或者开始比结束晚');
      return;
    }
    let list;
    if (r) {
      list = bulkSelectWithin(r[0], r[1], keep);
      if (!list.length) {
        toast(emptyTip);
        renderBulkCal();
        return;
      }
      renderBulkCal();
      bulkScrollToSel();
      return;
    }
    const scope = bulkScope();
    list = bulkDaysBetween(scope[0], scope[1], keep);
    if (!list.length) {
      toast(emptyTip);
      return;
    }
    bulkAddDates(list);
    renderBulkCal();
  }

  function bulkScrollToSel() {
    const first = Array.from(bulkSel).sort()[0];
    if (!first) return;
    const cell = bulkGrid.querySelector('.bulk-d[data-d="' + first + '"]');
    if (cell && cell.scrollIntoView) cell.scrollIntoView({ block: 'nearest' });
  }

  $('#bulkWork').addEventListener('click', () => {
    bulkQuick((ds) => weekdayOf(ds) <= 5, '这段里没有周中（周一到周五）');
  });

  $('#bulkRest').addEventListener('click', () => {
    bulkQuick((ds) => weekdayOf(ds) >= 6, '这段里没有周末');
  });

  function bulkWeekly(wd) {
    const r = bulkRangeInputs();
    if (r === 'bad') {
      toast('「从 / 到」没填对，或者开始比结束晚');
      return;
    }
    let list;
    if (r) {
      list = bulkSelectWithin(r[0], r[1], (ds) => weekdayOf(ds) === wd);
      if (!list.length) {
        toast('这段里没有这一天');
        renderBulkCal();
        return;
      }
      renderBulkCal();
      bulkScrollToSel();
      return;
    } else {
      let cur = todayStr();
      list = [];
      while (list.length < 12) {
        if (weekdayOf(cur) === wd) list.push(cur);
        cur = addDays(cur, 1);
      }
    }
    bulkMonth = list[0].slice(0, 7);
    bulkAddDates(list);
    renderBulkCal();
  }

  $('#bulkWeekly').addEventListener('click', (e) => {
    e.stopPropagation();
    const pop = $('#bulkWeekPop');
    pop.hidden = !pop.hidden;
  });
  $('#bulkWeekPop').addEventListener('click', (e) => {
    const b = e.target.closest ? e.target.closest('button[data-wd]') : null;
    if (!b) return;
    bulkWeekly(Number(b.dataset.wd));
    $('#bulkWeekPop').hidden = true;
  });
  document.addEventListener('click', (e) => {
    if (!e.target.closest || !e.target.closest('.bulk-week')) $('#bulkWeekPop').hidden = true;
  });

  function bulkAutoRange() {
    const r = bulkRangeInputs();
    if (!r || r === 'bad') return;
    const list = bulkSelectWithin(r[0], r[1], null);
    if (!list.length) {
      toast('这段都在过去');
      renderBulkCal();
      return;
    }
    renderBulkCal();
    bulkScrollToSel();
  }

  $('#bulkFrom').addEventListener('change', bulkAutoRange);
  $('#bulkTo').addEventListener('change', bulkAutoRange);

  $('#bulkPickRange').addEventListener('click', () => {
    const r = bulkRangeInputs();
    if (!r || r === 'bad') {
      toast('先把「从」和「到」都填上，开始不能比结束晚');
      return;
    }
    const list = bulkSelectWithin(r[0], r[1], null);
    if (!list.length) {
      toast('这段都在过去');
      renderBulkCal();
      return;
    }
    renderBulkCal();
    bulkScrollToSel();
  });

  function renderBulkSwatches() {
    const box = $('#bulkSwatches');
    box.innerHTML = '';
    COLORS.forEach((c, i) => {
      const btn = el('button', 'swatch' + (i === bulkColor ? ' is-on' : ''));
      btn.type = 'button';
      btn.style.background = c;
      btn.addEventListener('click', () => {
        bulkColor = i;
        renderBulkSwatches();
      });
      box.appendChild(btn);
    });
  }

  [bulkTitle, bulkStart, bulkEnd, bulkNote].forEach((inp) => {
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !bulkGo.disabled) {
        e.preventDefault();
        bulkApply();
      }
    });
  });

  bulkTitle.addEventListener('input', renderBulkSum);
  bulkStart.addEventListener('input', renderBulkSum);
  bulkEnd.addEventListener('input', renderBulkSum);

  function bulkApply() {
    const t = bulkTimes();
    const title = bulkTitle.value.trim();
    const days = Array.from(bulkSel).filter((d) => d >= todayStr()).sort();
    if (!title) { toast('先写一下这件事是什么'); return 0; }
    if (!t.dur) { toast('结束时间要比开始晚一点'); return 0; }
    if (!days.length) { toast('先在上面选几天'); return 0; }
    const note = bulkNote.value.trim();
    days.forEach((ds) => {
      store.blocks.push({
        id: uid(),
        date: ds,
        start: clamp(snap(t.a), 0, DAY - MIN_DUR),
        dur: clamp(t.dur, MIN_DUR, DAY),
        title: title,
        note: note,
        done: false,
        color: bulkColor,
        habitId: null,
        src: 'bulk',
      });
    });
    save();
    closeBulk();
    goDate(days[0]);
    requestAnimationFrame(() => {
      wrapEl.scrollTo({ top: Math.max(0, toY(t.a) - 140), behavior: 'smooth' });
    });
    toast('加了 ' + days.length + ' 条');
    return days.length;
  }

  function openBulk() {
    bulkMonth = todayStr().slice(0, 7);
    bulkSel.clear();
    bulkAnchor = null;
    bulkPaint = null;
    renderBulkSwatches();
    renderBulkCal();
    bulkModal.hidden = false;
    setTimeout(() => bulkTitle.focus(), 30);
  }

  function closeBulk() {
    bulkModal.hidden = true;
    $('#bulkWeekPop').hidden = true;
    bulkPaint = null;
  }

  $('#bulkBtn').addEventListener('click', openBulk);
  $('#bulkCancel').addEventListener('click', closeBulk);
  $('#bulkGo').addEventListener('click', () => bulkApply());
  bulkModal.addEventListener('click', (e) => {
    if (e.target === bulkModal) closeBulk();
  });

  /* ---------------- 提示 ---------------- */
  function toast(text) {
    const t = $('#toast');
    t.textContent = text;
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      t.hidden = true;
    }, 1900);
  }

  /* ---------------- 外部（原生）调用 ---------------- */
  window.Little = {
    clockTick: () => clockTick(),
    applyStore: function (next) {
      const wasEditing = editingId;
      store = normalize(next || {});
      renderAll();
      if (wasEditing && !blockById(wasEditing)) editingId = null;
    },
    setMode: function () {},
    goto: function (delta) { goDate(addDays(viewDate, delta)); },
    today: function () { goDate(todayStr()); },
    dump: function () {
      return JSON.stringify({ date: viewDate, blocks: store.blocks, habits: store.habits });
    },
    toast: toast,
    openSummary: openSummary,
    summary: function (span) { return summaryData(span || 'week'); },
    openBlock: openBlockModal,
    bulkOpen: openBulk,
    bulkPick: function (list) { (list || []).forEach((d) => bulkSel.add(d)); renderBulkCal(); },
    bulkApply: bulkApply,
    bulkSel: function () { return Array.from(bulkSel).sort(); },
    addNote: function (id, note) {
      const b = blockById(id);
      if (!b) return false;
      b.note = String(note || '');
      renderBlocks();
      save();
      return true;
    },
  };

  /* ---------------- 启动 ---------------- */
  // 上次没收尾的空壳，开机时清掉（会话里调时间留下的空块不动）
  store.blocks = store.blocks.filter((b) => (b.title || '').trim());
  buildGrid();
  renderAll();
  scrollToNow();

  // 每 20 秒对一次表：挪「现在」那条线；跨过午夜就自动翻到新的一天
  function clockTick() {
    const d = todayStr();
    if (followToday && d !== viewDate) {
      viewDate = d;
      selectedId = null;
      editingId = null;
      renderAll();
      scrollToNow();
      return;
    }
    if (viewDate === d) renderNow();
  }
  setInterval(clockTick, 20000);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) clockTick();
  });

  requestAnimationFrame(() => {
    requestAnimationFrame(() => post({ cmd: 'rendered' }));
  });
})();
