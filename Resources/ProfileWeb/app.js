(() => {
  'use strict';

  const $ = selector => document.querySelector(selector);
  const decoder = new TextDecoder();
  const state = {
    processes: [],
    runs: [],
    selectedPID: 0,
    selectedID: 0,
    recording: false,
    activeID: 0,
    profile: null,
    range: [0, 0],
    zoom: 1,
    flameSource: null,
    flameDepth: 0,
    pinch: null,
    drag: null,
    showingSetup: true,
    perf: { path: '/usr/bin/perf', usable: true, message: '', machineUnsupported: false },
    picker: null,
    pickerSelection: null
  };

  const u32 = (view, offset) => view.getUint32(offset, true);
  const i32 = (view, offset) => view.getInt32(offset, true);
  const u64 = (view, offset) => Number(view.getBigUint64(offset, true));
  const f64 = (view, offset) => view.getFloat64(offset, true);
  const stringAt = (buffer, view, offset) => {
    const start = u32(view, offset);
    const length = u32(view, offset + 4);
    return start + length <= buffer.byteLength
      ? decoder.decode(new Uint8Array(buffer, start, length))
      : '';
  };

  function base(buffer, type) {
    const view = new DataView(buffer);
    if (buffer.byteLength < 16 || decoder.decode(new Uint8Array(buffer, 0, 4)) !== 'PRFL' || u32(view, 8) !== type) {
      throw Error('Invalid Profile response');
    }
    return view;
  }

  function parseProcesses(buffer) {
    const view = base(buffer, 1);
    const count = u32(view, 16);
    const offset = u32(view, 20);
    return Array.from({ length: count }, (_, index) => {
      const row = offset + index * 56;
      return {
        pid: i32(view, row),
        ppid: i32(view, row + 4),
        name: stringAt(buffer, view, row + 8),
        command: stringAt(buffer, view, row + 16),
        container: stringAt(buffer, view, row + 24),
        containerID: stringAt(buffer, view, row + 32),
        localPID: i32(view, row + 40),
        startTime: u64(view, row + 48)
      };
    });
  }

  function parseRuns(buffer) {
    const view = base(buffer, 2);
    const count = u32(view, 28);
    const offset = u32(view, 32);
    return {
      recording: Boolean(u32(view, 16)),
      active: u64(view, 20),
      runs: Array.from({ length: count }, (_, index) => {
        const row = offset + index * 72;
        return {
          id: u64(view, row),
          pid: i32(view, row + 8),
          frequency: i32(view, row + 12),
          samples: u32(view, row + 16),
          duration: f64(view, row + 24),
          cpu: f64(view, row + 32),
          status: stringAt(buffer, view, row + 40),
          container: stringAt(buffer, view, row + 48),
          containerID: stringAt(buffer, view, row + 56),
          localPID: i32(view, row + 64)
        };
      })
    };
  }

  function parseProfile(buffer) {
    const view = base(buffer, 4);
    const timelineCount = u32(view, 108);
    const timelineOffset = u32(view, 112);
    const foldedCount = u32(view, 116);
    const foldedOffset = u32(view, 120);
    const frameCount = u32(view, 124);
    const frameOffset = u32(view, 128);
    const frames = [];
    for (let index = 0; index < frameCount; index++) {
      const row = frameOffset + index * 16;
      frames.push({ symbol: stringAt(buffer, view, row), binary: stringAt(buffer, view, row + 8) });
    }
    const timeline = [];
    for (let index = 0; index < timelineCount; index++) {
      const row = timelineOffset + index * 32;
      timeline.push({
        start: f64(view, row),
        end: f64(view, row + 8),
        cpu: f64(view, row + 16),
        samples: u32(view, row + 24)
      });
    }
    const folded = [];
    for (let index = 0; index < foldedCount; index++) {
      const row = foldedOffset + index * 12;
      const count = u32(view, row);
      const depth = u32(view, row + 4);
      const first = u32(view, row + 8);
      folded.push({ count, stack: frames.slice(first, first + depth) });
    }
    return {
      id: u64(view, 16),
      pid: i32(view, 24),
      duration: i32(view, 28),
      frequency: i32(view, 32),
      cpu: f64(view, 40),
      start: f64(view, 48),
      end: f64(view, 56),
      samples: u32(view, 64),
      total: u32(view, 68),
      aggregates: u32(view, 72),
      status: stringAt(buffer, view, 84),
      timeline,
      folded
    };
  }

  function parsePerf(buffer) {
    const view = base(buffer, 5);
    return {
      usable: Boolean(u32(view, 16)),
      path: stringAt(buffer, view, 20),
      message: stringAt(buffer, view, 28),
      machineUnsupported: buffer.byteLength >= 48 && Boolean(u32(view, 44))
    };
  }

  function parseFilePicker(buffer) {
    const view = base(buffer, 6);
    const count = u32(view, 32);
    const rowsOffset = u32(view, 36);
    return {
      path: stringAt(buffer, view, 16),
      parent: stringAt(buffer, view, 24),
      entries: Array.from({ length: count }, (_, index) => {
        const row = rowsOffset + index * 32;
        return {
          name: stringAt(buffer, view, row),
          path: stringAt(buffer, view, row + 8),
          directory: Boolean(u32(view, row + 16) & 1)
        };
      })
    };
  }

  function selectedProcess() {
    return state.processes.find(process => process.pid === state.selectedPID);
  }

  function setSetupStatus(message) {
    $('#setupStatus').textContent = message;
  }

  function setProfileStatus(message) {
    $('#summary').textContent = message;
  }

  function setSidebarOpen(open) {
    $('#recordingSidebar').classList.toggle('open', open);
    $('#drawerScrim').classList.toggle('open', open);
    for (const button of document.querySelectorAll('.sidebar-toggle')) {
      button.setAttribute('aria-expanded', open ? 'true' : 'false');
    }
  }

  function closeSidebar() {
    setSidebarOpen(false);
  }

  let profileLoadGeneration = 0;
  let restoredTraceURL = null;

  function updateTraceURL(id) {
    const url = new URL(location.href);
    url.pathname = id ? `/traces/${id}` : '/';
    url.hash = '';
    if (url.href !== location.href) history.pushState(null, '', url);
    restoredTraceURL = location.href;
  }

  function restoreTraceURL() {
    if (restoredTraceURL === location.href) return;
    restoredTraceURL = location.href;
    const match = /^\/traces\/([1-9][0-9]*)$/.exec(location.pathname);
    if (match && Number.isSafeInteger(Number(match[1]))) loadProfile(Number(match[1]));
    else showSetup();
  }

  function showSetup() {
    profileLoadGeneration++;
    updateTraceURL(null);
    state.showingSetup = true;
    state.selectedID = 0;
    $('#setupView').hidden = false;
    $('#profileView').hidden = true;
    $('#nextRecording').classList.add('selected');
    renderRuns();
    updateRecordingControls();
    closeSidebar();
  }

  function showProfile() {
    state.showingSetup = false;
    $('#setupView').hidden = true;
    $('#profileView').hidden = false;
    $('#nextRecording').classList.remove('selected');
    renderRuns();
    updateRecordingControls();
    closeSidebar();
  }

  function setupStatusText() {
    if (state.recording) return `Recording pid ${state.selectedPID} at 1000 Hz…`;
    const process = selectedProcess();
    if (process) return `Next recording target: ${process.name} (${process.localPID || process.pid}) · ${process.container}.`;
    if (!state.perf.usable && state.perf.message) return state.perf.message;
    return 'Choose a process for the next recording.';
  }

  function updateRecordingControls() {
    const ready = Boolean(state.selectedPID && state.perf.usable && !state.perf.machineUnsupported);
    for (const button of [$('#record'), $('#recordProfile')]) {
      button.classList.toggle('ready', ready && !state.recording);
      button.classList.toggle('active', state.recording);
      button.setAttribute('aria-label', state.recording ? 'Stop recording' : 'Start recording');
    }
    $('#sidebarTarget').textContent = selectedProcess()
      ? `${selectedProcess().container} · ${selectedProcess().name} (${selectedProcess().localPID || state.selectedPID})`
      : 'Choose a target';
    if (state.showingSetup) setSetupStatus(setupStatusText());
  }

  async function refreshProcesses() {
    const previous = $('#refreshProcesses').textContent;
    $('#refreshProcesses').disabled = true;
    $('#refreshProcesses').textContent = 'Refreshing…';
    setSetupStatus('Refreshing processes…');
    try {
      const response = await fetch('/api/processes?containers=1');
      if (!response.ok) throw Error(await response.text());
      const previousStart = selectedProcess()?.startTime;
      state.processes = parseProcesses(await response.arrayBuffer());
      const picker = $('#container');
      const selected = picker.value;
      const environments = new Map(state.processes.map(process => [process.containerID, process.container]));
      picker.replaceChildren(new Option('All containers and host', ''), ...[...environments].map(([id, name]) => new Option(name, id)));
      if (environments.has(selected)) picker.value = selected;
      if (state.selectedPID && (!selectedProcess() || selectedProcess().startTime !== previousStart)) state.selectedPID = 0;
      renderProcesses();
      updateRecordingControls();
    } catch (error) {
      setSetupStatus(error.message || 'Could not load processes.');
    } finally {
      $('#refreshProcesses').disabled = false;
      $('#refreshProcesses').textContent = previous;
    }
  }

  function renderProcesses() {
    const query = $('#processSearch').value.trim().toLowerCase();
    const matches = state.processes.filter(process =>
      (!$('#container').value || process.containerID === $('#container').value) && (
      !query || process.name.toLowerCase().includes(query) ||
      process.command.toLowerCase().includes(query) || String(process.pid).includes(query) || String(process.localPID).includes(query) || process.container.toLowerCase().includes(query))
    ).slice(0, 1000);
    if (!matches.length) {
      const empty = document.createElement('div');
      empty.className = 'empty-row';
      empty.textContent = state.processes.length ? 'No matching processes' : 'No processes available';
      $('#processes').replaceChildren(empty);
      return;
    }
    $('#processes').replaceChildren(...matches.map(process => {
      const row = document.createElement('div');
      row.className = 'process-row' + (process.pid === state.selectedPID ? ' selected' : '');
      row.setAttribute('role', 'option');
      row.setAttribute('aria-selected', process.pid === state.selectedPID ? 'true' : 'false');
      row.title = `${process.container} · host PID ${process.pid}\n${process.command || process.name}`;
      row.innerHTML = '<span class="pid"></span><span class="name"></span>';
      row.firstChild.textContent = process.localPID || process.pid;
      row.lastChild.textContent = $('#container').value ? process.name : `${process.name} — ${process.container}`;
      row.onclick = () => {
        state.selectedPID = process.pid;
        renderProcesses();
        updateRecordingControls();
      };
      return row;
    }));
  }

  async function refreshPerf(path) {
    const query = path == null ? '' : '?' + new URLSearchParams({ path });
    if (path != null) setSetupStatus('Checking perf…');
    try {
      const response = await fetch('/api/perf' + query);
      if (!response.ok) throw Error(await response.text());
      state.perf = parsePerf(await response.arrayBuffer());
      if (document.activeElement !== $('#perfPath')) $('#perfPath').value = state.perf.path;
      $('#perfMessage').textContent = state.perf.message || (state.perf.usable ? 'perf is usable' : 'perf is not usable');
      $('#perfMessage').classList.toggle('error', !state.perf.usable);
      updateRecordingControls();
      if (path != null) setSetupStatus(state.perf.usable ? `Using ${state.perf.path}.` : state.perf.message);
    } catch (error) {
      $('#perfMessage').textContent = error.message || 'Could not check perf.';
      $('#perfMessage').classList.add('error');
      setSetupStatus(error.message || 'Could not check perf.');
    }
  }

  async function refreshRuns() {
    try {
      const response = await fetch('/api/profiles?containers=1');
      if (!response.ok) throw Error(await response.text());
      const result = parseRuns(await response.arrayBuffer());
      state.recording = result.recording;
      state.activeID = result.active;
      state.runs = result.runs;
      if (state.recording && !state.showingSetup && !state.selectedID) state.selectedID = state.activeID;
      renderRuns();
      updateRecordingControls();
    } catch (error) {
      if (state.showingSetup) setSetupStatus(error.message || 'Could not load recordings.');
      else setProfileStatus(error.message || 'Could not load recordings.');
    }
  }

  function renderRuns() {
    const rows = [];
    if (state.recording && state.activeID && !state.runs.some(run => run.id === state.activeID)) {
      const active = document.createElement('div');
      active.className = 'trace' + (!state.showingSetup && state.activeID === state.selectedID ? ' selected' : '');
      active.innerHTML = '<strong>Recording</strong><small></small>';
      active.lastChild.textContent = state.selectedPID ? `pid ${state.selectedPID}  Recording` : 'Recording';
      rows.push(active);
    }
    rows.push(...[...state.runs].reverse().map((run, index) => {
      const row = document.createElement('div');
      row.className = 'trace' + (!state.showingSetup && run.id === state.selectedID ? ' selected' : '');
      row.innerHTML = '<strong></strong><small></small>';
      row.firstChild.textContent = `Run ${state.runs.length - index}`;
      row.lastChild.textContent = `${run.container} · pid ${run.localPID || run.pid} · ${run.duration.toFixed(2)} s`;
      row.onclick = () => loadProfile(run.id);
      return row;
    }));
    $('#traces').replaceChildren(...rows);
  }

  async function loadProfile(id, start, end) {
    const generation = ++profileLoadGeneration;
    updateTraceURL(id);
    state.selectedID = Number(id);
    if (state.profile?.id !== state.selectedID) clearProfileDisplay('Loading recording…');
    showProfile();
    setProfileStatus('Loading recording…');
    try {
      const query = new URLSearchParams({ profileID: id });
      if (start != null) {
        query.set('start', start);
        query.set('end', end);
      }
      const response = await fetch('/api/profile/range?' + query);
      if (!response.ok) throw Error(await response.text());
      const profile = parseProfile(await response.arrayBuffer());
      if (generation !== profileLoadGeneration) return;
      state.profile = profile;
      state.selectedID = state.profile.id;
      state.range = [state.profile.start, state.profile.end];
      renderRuns();
      renderProfile();
    } catch (error) {
      if (generation !== profileLoadGeneration) return;
      setProfileStatus(error.message || 'Could not load recording.');
    }
  }

  function renderProfile() {
    const profile = state.profile;
    const duration = profile.end - profile.start;
    setProfileStatus(`Captured ${profile.samples} samples across ${profile.aggregates} stacks in ${duration.toFixed(2)} s${profile.cpu >= 0 ? `, ${profile.cpu.toFixed(1)} ms CPU total.` : '.'}`);
    $('#rangeLabel').textContent = `${formatTime(profile.start)} – ${formatTime(profile.end)} selected (${formatTime(duration)})`;
    $('#flameTitle').textContent = `Profile  pid ${profile.pid}, ${profile.duration.toFixed(2)} s at ${profile.frequency} Hz`;
    requestAnimationFrame(() => {
      drawTimeline();
      renderFlame();
    });
  }

  function clearProfileDisplay(message) {
    state.profile = null;
    state.flameSource = null;
    state.flameDepth = 0;
    const canvas = $('#chart');
    canvas.getContext('2d').clearRect(0, 0, canvas.width, canvas.height);
    $('#leftHandle').style.left = '0%';
    $('#rightHandle').style.left = '100%';
    $('#shadeLeft').style.width = '0%';
    $('#shadeRight').style.width = '0%';
    $('#rangeLabel').textContent = message;
    $('#flameTitle').textContent = '';
    clearTimeout(flameView.settleTimer);
    flameView.settleTimer = null;
    cancelAnimationFrame(flameView.frame);
    flameView.frame = 0;
    flameView.rows = [];
    flameView.active.clear();
    flameView.pool = [];
    flameView.boxes = flameView.labels = null;
    $('#flame').replaceChildren();
  }

  function drawTimeline() {
    if (!state.profile) return;
    const profile = state.profile;
    const canvas = $('#chart');
    const rect = $('#timeline').getBoundingClientRect();
    const dpr = devicePixelRatio || 1;
    canvas.width = Math.max(1, rect.width * dpr);
    canvas.height = Math.max(1, rect.height * dpr);
    const context = canvas.getContext('2d');
    context.scale(dpr, dpr);
    context.clearRect(0, 0, rect.width, rect.height);
    const maximum = Math.max(1, ...profile.timeline.map(bucket => bucket.cpu));
    context.fillStyle = '#159cdc';
    profile.timeline.forEach((bucket, index) => {
      const x = index / profile.timeline.length * rect.width;
      const width = Math.max(1, rect.width / profile.timeline.length);
      const height = Math.min(rect.height, bucket.cpu / maximum * rect.height * .92);
      context.fillRect(x, rect.height - height, width, height);
    });
    updateSelection();
  }

  function updateSelection() {
    if (!state.profile) return;
    const full = Math.max(.001, state.profile.timeline.at(-1)?.end || state.profile.duration);
    const left = state.range[0] / full * 100;
    const right = state.range[1] / full * 100;
    $('#leftHandle').style.left = left + '%';
    $('#rightHandle').style.left = right + '%';
    $('#shadeLeft').style.width = left + '%';
    $('#shadeRight').style.width = (100 - right) + '%';
  }

  function tree() {
    const root = { count: 0, children: new Map() };
    for (const folded of state.profile.folded) {
      root.count += folded.count;
      let node = root;
      for (const frame of folded.stack) {
        const key = frame.symbol + '\0' + frame.binary;
        if (!node.children.has(key)) node.children.set(key, { frame, count: 0, children: new Map() });
        node = node.children.get(key);
        node.count += folded.count;
      }
    }
    return root;
  }

  function color(value) {
    let hash = 2166136261;
    for (const character of value) hash = Math.imul(hash ^ character.charCodeAt(0), 16777619);
    return `hsl(${Math.abs(hash) % 360} 30% 53%)`;
  }

  const flameView = { rows: [], boxes: null, labels: null, active: new Map(), pool: [], width: 0, height: 0,
    left: 0, top: 0, frame: 0, zoomDirty: false, boxZoom: 1, commitDirty: false, settleTimer: null };

  function firstFlameItem(row, fraction) {
    let low = 0, high = row.length;
    while (low < high) {
      const mid = (low + high) >>> 1;
      if (row[mid].x + row[mid].width <= fraction) low = mid + 1;
      else high = mid;
    }
    return low;
  }

  function rebuildFlame() {
    clearTimeout(flameView.settleTimer);
    flameView.settleTimer = null;
    const root = tree();
    const items = [];
    flameView.rows = [];
    function walk(node, x, width, depth) {
      let cursor = x;
      const children = [...node.children.values()].sort((a, b) => b.count - a.count || a.frame.symbol.localeCompare(b.frame.symbol));
      for (const child of children) {
        const childWidth = width * child.count / Math.max(1, node.count);
        const item = { node: child, x: cursor, width: childWidth, depth, id: items.length };
        items.push(item);
        (flameView.rows[depth] ||= []).push(item);
        walk(child, cursor, childWidth, depth + 1);
        cursor += childWidth;
      }
    }
    walk(root, 0, 1, 0);
    state.flameSource = state.profile;
    state.flameDepth = flameView.rows.length;
    flameView.active.clear();
    flameView.pool = [];
    flameView.boxes = document.createElement('div');
    flameView.boxes.className = 'flame-boxes';
    flameView.boxes.setAttribute('aria-hidden', 'true');
    flameView.labels = document.createElement('div');
    flameView.labels.className = 'flame-labels';
    flameView.boxes.replaceChildren(...items.map(item => {
      const element = document.createElement('div');
      element.className = 'frame';
      element.style.top = item.depth * 31 + 'px';
      element.style.background = color(item.node.frame.binary || item.node.frame.symbol);
      item.box = element;
      return element;
    }));
    $('#flame').replaceChildren(flameView.boxes, flameView.labels);
    flameView.width = 0;
  }

  function updateFlameLabels() {
    const width = flameView.width * state.zoom;
    const firstDepth = Math.max(0, Math.floor(flameView.top / 31));
    const lastDepth = Math.min(flameView.rows.length, Math.ceil((flameView.top + flameView.height) / 31));
    const visible = [];
    for (let depth = firstDepth; depth < lastDepth; depth++) {
      const row = flameView.rows[depth];
      for (let index = firstFlameItem(row, flameView.left / width); index < row.length; index++) {
        const item = row[index];
        const left = item.x * width;
        if (left >= flameView.left + flameView.width) break;
        const right = Math.min(left + item.width * width, flameView.left + flameView.width);
        const clippedLeft = Math.max(left, flameView.left);
        if (right - clippedLeft >= 34) visible.push({ item, left: clippedLeft, width: right - clippedLeft });
      }
    }
    const ids = new Set(visible.map(entry => entry.item.id));
    for (const [id, label] of flameView.active) {
      if (!ids.has(id)) {
        label.remove();
        flameView.active.delete(id);
        flameView.pool.push(label);
      }
    }
    for (const entry of visible) {
      const { item } = entry;
      let label = flameView.active.get(item.id);
      if (!label) {
        label = flameView.pool.pop() || document.createElement('div');
        label.className = 'flame-label';
        label.innerHTML = '<b></b><small></small>';
        label.firstChild.textContent = item.node.frame.symbol;
        label.lastChild.textContent = item.node.frame.binary;
        label.tabIndex = 0;
        label.setAttribute('role', 'button');
        label.setAttribute('aria-label', `${item.node.frame.symbol}, ${item.node.frame.binary}, ${item.node.count} samples. Zoom in`);
        label.onkeydown = event => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            zoomAt(item.x + item.width / 2, 2);
          }
        };
        flameView.labels.append(label);
        flameView.active.set(item.id, label);
      }
      label.classList.toggle('single', !item.node.frame.binary || entry.width < 54);
      label.style.transform = `translate(${entry.left}px, ${item.depth * 31}px)`;
      label.style.width = entry.width + 'px';
    }
  }

  function commitFlameBoxes() {
    const width = flameView.width * state.zoom;
    flameView.boxes.style.width = width + 'px';
    for (const row of flameView.rows) for (const item of row) {
      item.box.style.left = item.x * width + 'px';
      item.box.style.width = item.width * width + 'px';
    }
    flameView.boxZoom = state.zoom;
    flameView.boxes.style.transform = 'none';
    flameView.boxes.style.willChange = 'auto';
    flameView.commitDirty = false;
  }

  function settleFlameZoom() {
    clearTimeout(flameView.settleTimer);
    flameView.settleTimer = null;
    flameView.commitDirty = true;
    scheduleFlameView();
  }

  function applyFlameView() {
    flameView.frame = 0;
    if (!state.profile || !flameView.boxes || !flameView.width) return;
    const viewport = $('#flameViewport');
    const width = flameView.width * state.zoom;
    if (flameView.commitDirty) commitFlameBoxes();
    if (flameView.zoomDirty) {
      flameView.left = Math.max(0, Math.min(width - flameView.width, flameView.left));
      $('#flame').style.width = width + 'px';
      const scale = state.zoom / flameView.boxZoom;
      flameView.boxes.style.willChange = scale === 1 ? 'auto' : 'transform';
      flameView.boxes.style.transform = scale === 1 ? 'none' : `scaleX(${scale})`;
      viewport.scrollLeft = flameView.left;
      $('#zoomReset').textContent = Math.round(state.zoom * 100) + '%';
      flameView.zoomDirty = false;
    }
    updateFlameLabels();
  }

  function scheduleFlameView() {
    if (!flameView.frame) flameView.frame = requestAnimationFrame(applyFlameView);
  }

  function layoutFlame() {
    if (!state.profile) return;
    const viewport = $('#flameViewport');
    const width = viewport.clientWidth;
    const height = viewport.clientHeight;
    if (width !== flameView.width) {
      const fraction = flameView.width ? flameView.left / (flameView.width * state.zoom) : 0;
      flameView.width = width;
      flameView.left = fraction * width * state.zoom;
      flameView.commitDirty = true;
    }
    flameView.height = height;
    flameView.top = viewport.scrollTop;
    $('#flame').style.height = Math.max(height, state.flameDepth * 31) + 'px';
    flameView.zoomDirty = true;
    scheduleFlameView();
  }

  function renderFlame() {
    if (!state.profile) return;
    if (state.flameSource !== state.profile) rebuildFlame();
    layoutFlame();
  }

  function setZoom(zoom, anchorFraction, anchorX) {
    if (!state.profile || !flameView.width) return;
    const localX = anchorX == null ? flameView.width / 2 : anchorX;
    const fraction = anchorFraction == null ? (flameView.left + localX) / (flameView.width * state.zoom) : anchorFraction;
    if (!Number.isFinite(zoom) || !Number.isFinite(zoom * flameView.width)) return;
    state.zoom = Math.max(1, zoom);
    flameView.left = Math.max(0, Math.min(flameView.width * (state.zoom - 1), fraction * flameView.width * state.zoom - localX));
    flameView.zoomDirty = true;
    $('#flameViewport').removeAttribute('title');
    clearTimeout(flameView.settleTimer);
    flameView.settleTimer = state.pinch ? null : setTimeout(settleFlameZoom, 180);
    scheduleFlameView();
  }

  function zoomAt(factor, multiplier) {
    setZoom(state.zoom * multiplier, factor, flameView.width / 2);
  }

  function flameAnchor(clientX) {
    const rect = $('#flameViewport').getBoundingClientRect();
    const proposed = Number.isFinite(clientX) ? clientX - rect.left : flameView.width / 2;
    const x = Math.max(0, Math.min(flameView.width, proposed));
    return { x, fraction: (flameView.left + x) / Math.max(1, flameView.width * state.zoom) };
  }

  function beginPinch(clientX, distance = 1) {
    clearTimeout(flameView.settleTimer);
    flameView.settleTimer = null;
    const anchor = flameAnchor(clientX);
    state.pinch = { zoom: state.zoom, anchor: anchor.fraction, x: anchor.x, distance };
  }

  function updatePinch(scale) {
    if (!state.pinch || !Number.isFinite(scale) || scale <= 0) return;
    setZoom(state.pinch.zoom * scale, state.pinch.anchor, state.pinch.x);
  }

  function endPinch() {
    state.pinch = null;
    settleFlameZoom();
  }

  function flameItemAt(clientX, clientY) {
    const viewport = $('#flameViewport');
    const rect = viewport.getBoundingClientRect();
    const depth = Math.floor((clientY - rect.top + viewport.scrollTop) / 31);
    const row = flameView.rows[depth];
    if (!row) return null;
    const x = (clientX - rect.left + flameView.left) / (flameView.width * state.zoom);
    const item = row[firstFlameItem(row, x)];
    return item && item.x <= x ? item : null;
  }

  function formatTime(value) {
    return value < 1 ? `${Math.round(value * 1000)} ms` : `${value.toFixed(2)} s`;
  }

  function pointerFraction(event) {
    const rect = $('#timeline').getBoundingClientRect();
    return Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
  }

  function beginDrag(event, kind) {
    if (!state.profile) return;
    event.preventDefault();
    state.drag = { kind };
    event.currentTarget?.setPointerCapture?.(event.pointerId);
    moveDrag(event);
  }

  function moveDrag(event) {
    if (!state.drag || !state.profile) return;
    const full = state.profile.timeline.at(-1)?.end || state.profile.duration;
    const value = pointerFraction(event) * full;
    if (state.drag.kind === 'left') state.range[0] = Math.min(value, state.range[1] - .001);
    else if (state.drag.kind === 'right') state.range[1] = Math.max(value, state.range[0] + .001);
    else {
      if (state.drag.origin == null) {
        state.drag.origin = value;
        state.range = [value, value];
      }
      state.range = [Math.min(state.drag.origin, value), Math.max(state.drag.origin, value)];
    }
    updateSelection();
    $('#rangeLabel').textContent = `${formatTime(state.range[0])} – ${formatTime(state.range[1])} selected`;
  }

  async function endDrag() {
    if (!state.drag) return;
    state.drag = null;
    if (state.profile && state.range[1] > state.range[0]) {
      await loadProfile(state.profile.id, state.range[0], state.range[1]);
    }
  }

  async function toggleRecording() {
    if (state.recording) {
      showProfile();
      setProfileStatus('Stopping recording and building profile…');
      try {
        const response = await fetch('/api/profile/stop');
        if (!response.ok) throw Error(await response.text());
        state.profile = parseProfile(await response.arrayBuffer());
        state.selectedID = state.profile.id;
        updateTraceURL(state.selectedID);
        state.recording = false;
        state.range = [state.profile.start, state.profile.end];
        renderProfile();
        await refreshRuns();
      } catch (error) {
        setProfileStatus(error.message || 'Could not stop recording.');
      }
      return;
    }

    if (!state.selectedPID) {
      showSetup();
      setSetupStatus('Select a process first.');
      return;
    }
    if (!state.perf.usable || state.perf.machineUnsupported) {
      showSetup();
      setSetupStatus(state.perf.message || 'perf is not available.');
      return;
    }

    const query = new URLSearchParams({
      pid: state.selectedPID,
      startTime: selectedProcess()?.startTime || 0,
      container: selectedProcess()?.containerID || "unknown",
      frequency: 1000,
      perfPath: $('#perfPath').value.trim()
    });
    setSetupStatus(`Starting recording for pid ${state.selectedPID}…`);
    try {
      const response = await fetch('/api/profile/start?' + query);
      if (!response.ok) throw Error(await response.text());
      state.recording = true;
      state.selectedID = 0;
      showProfile();
      clearProfileDisplay('Recording in progress');
      setProfileStatus(`Recording pid ${state.selectedPID} at 1000 Hz…`);
      await refreshRuns();
    } catch (error) {
      showSetup();
      setSetupStatus(error.message || 'Could not start recording.');
    }
  }

  async function openPerfPicker() {
    const value = $('#perfPath').value.trim();
    const slash = value.lastIndexOf('/');
    const initial = value.startsWith('/') ? (slash > 0 ? value.slice(0, slash) : '/') : '/';
    state.pickerSelection = null;
    const dialog = $('#perfPicker');
    if (typeof dialog.showModal === 'function') dialog.showModal();
    else dialog.setAttribute('open', '');
    await loadPicker(initial);
  }

  async function loadPicker(path) {
    $('#pickerPath').textContent = path;
    $('#pickerEntries').replaceChildren(Object.assign(document.createElement('div'), { className: 'empty-row', textContent: 'Loading…' }));
    try {
      const response = await fetch('/api/file-picker?' + new URLSearchParams({ path }));
      if (!response.ok) throw Error(await response.text());
      state.picker = parseFilePicker(await response.arrayBuffer());
      state.pickerSelection = null;
      renderPicker();
    } catch (error) {
      $('#pickerEntries').replaceChildren(Object.assign(document.createElement('div'), { className: 'empty-row', textContent: error.message || 'Could not load directory.' }));
    }
  }

  function renderPicker() {
    $('#pickerPath').textContent = state.picker.path;
    $('#pickerUp').disabled = state.picker.path === state.picker.parent;
    $('#choosePerf').disabled = !state.pickerSelection || state.pickerSelection.directory;
    $('#pickerEntries').replaceChildren(...state.picker.entries.map(entry => {
      const row = document.createElement('div');
      row.className = 'picker-entry' + (state.pickerSelection?.path === entry.path ? ' selected' : '');
      row.innerHTML = '<span></span><span></span>';
      row.firstChild.textContent = entry.directory ? '▸' : '•';
      row.lastChild.textContent = entry.name;
      row.onclick = () => {
        state.pickerSelection = entry;
        renderPicker();
      };
      row.ondblclick = () => entry.directory ? loadPicker(entry.path) : choosePerf();
      return row;
    }));
  }

  function choosePerf() {
    if (!state.pickerSelection || state.pickerSelection.directory) return;
    $('#perfPath').value = state.pickerSelection.path;
    $('#perfPicker').close();
    refreshPerf(state.pickerSelection.path);
  }

  $('#nextRecording').onclick = showSetup;
  for (const button of document.querySelectorAll('.sidebar-toggle')) {
    button.onclick = () => {
      const open = !$('#recordingSidebar').classList.contains('open');
      setSidebarOpen(open);
      if (open) $('#sidebarClose').focus({ preventScroll: true });
    };
  }
  $('#sidebarClose').onclick = closeSidebar;
  $('#drawerScrim').onclick = closeSidebar;
  window.addEventListener('keydown', event => {
    if (event.key === 'Escape') closeSidebar();
  });
  $('#refreshProcesses').onclick = refreshProcesses;
  $('#processSearch').oninput = renderProcesses;
  $('#container').onchange = () => { state.selectedPID = 0; renderProcesses(); updateRecordingControls(); };
  $('#record').onclick = toggleRecording;
  $('#recordProfile').onclick = toggleRecording;
  $('#perfPath').onchange = () => refreshPerf($('#perfPath').value.trim());
  $('#selectPerf').onclick = openPerfPicker;
  $('#pickerUp').onclick = () => state.picker && loadPicker(state.picker.parent);
  $('#choosePerf').onclick = choosePerf;
  $('#timeline').onpointerdown = event => beginDrag(event, 'range');
  $('#leftHandle').onpointerdown = event => beginDrag(event, 'left');
  $('#rightHandle').onpointerdown = event => beginDrag(event, 'right');
  window.addEventListener('pointermove', moveDrag);
  window.addEventListener('pointerup', endDrag);
  $('#zoomIn').onclick = () => zoomAt(null, 1.5);
  $('#zoomOut').onclick = () => zoomAt(null, 1 / 1.5);
  $('#zoomReset').onclick = () => {
    setZoom(1, 0, 0);
  };
  const flameViewport = $('#flameViewport');
  flameViewport.addEventListener('scroll', () => {
    if (!flameView.zoomDirty) flameView.left = Math.max(0, flameViewport.scrollLeft);
    flameView.top = Math.max(0, flameViewport.scrollTop);
    scheduleFlameView();
  }, { passive: true });
  flameViewport.addEventListener('dblclick', event => {
    const item = flameItemAt(event.clientX, event.clientY);
    if (item) zoomAt(item.x + item.width / 2, 2);
  });
  flameViewport.addEventListener('pointermove', event => {
    if (state.pinch || event.pointerType === 'touch') return;
    const item = flameItemAt(event.clientX, event.clientY);
    flameViewport.title = item ? `${item.node.frame.symbol}\n${item.node.frame.binary}\n${item.node.count} samples` : '';
  });

  flameViewport.addEventListener('wheel', event => {
    if (event.ctrlKey || event.metaKey) {
      event.preventDefault();
      if (state.pinch) return;
      const anchor = flameAnchor(event.clientX);
      const units = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? flameViewport.clientHeight : 1);
      const continuousDelta = Math.max(-60, Math.min(60, units));
      setZoom(state.zoom * Math.exp(-continuousDelta * .01), anchor.fraction, anchor.x);
    }
  }, { passive: false });
  if ('ongesturestart' in window) {
    flameViewport.addEventListener('gesturestart', event => {
      event.preventDefault();
      beginPinch(event.clientX);
    }, { passive: false });
    flameViewport.addEventListener('gesturechange', event => {
      event.preventDefault();
      updatePinch(event.scale);
    }, { passive: false });
    flameViewport.addEventListener('gestureend', event => {
      event.preventDefault();
      endPinch();
    }, { passive: false });
  } else {
    const touchGeometry = touches => {
      const first = touches[0];
      const second = touches[1];
      return {
        x: (first.clientX + second.clientX) / 2,
        distance: Math.hypot(second.clientX - first.clientX, second.clientY - first.clientY)
      };
    };
    flameViewport.addEventListener('touchstart', event => {
      if (event.touches.length !== 2) return;
      event.preventDefault();
      const geometry = touchGeometry(event.touches);
      beginPinch(geometry.x, geometry.distance);
    }, { passive: false });
    flameViewport.addEventListener('touchmove', event => {
      if (!state.pinch || event.touches.length !== 2) return;
      event.preventDefault();
      const geometry = touchGeometry(event.touches);
      updatePinch(geometry.distance / Math.max(1, state.pinch.distance));
    }, { passive: false });
    flameViewport.addEventListener('touchend', endPinch, { passive: true });
    flameViewport.addEventListener('touchcancel', endPinch, { passive: true });
  }
  window.addEventListener('resize', () => {
    if (window.innerWidth > 950) closeSidebar();
    if (state.profile && !state.showingSetup) {
      drawTimeline();
      renderFlame();
    }
  });

  window.addEventListener('popstate', restoreTraceURL);
  restoreTraceURL();
  Promise.all([refreshProcesses(), refreshPerf(), refreshRuns()]);
  setInterval(() => { if (state.recording) refreshRuns(); }, 1000);
})();
