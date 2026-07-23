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
    pinchEndTimer: null,
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
      const row = offset + index * 24;
      return {
        pid: i32(view, row),
        ppid: i32(view, row + 4),
        name: stringAt(buffer, view, row + 8),
        command: stringAt(buffer, view, row + 16)
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
        const row = offset + index * 48;
        return {
          id: u64(view, row),
          pid: i32(view, row + 8),
          frequency: i32(view, row + 12),
          samples: u32(view, row + 16),
          duration: f64(view, row + 24),
          cpu: f64(view, row + 32),
          status: stringAt(buffer, view, row + 40)
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

  function showSetup() {
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
    if (process) return `Next recording target: ${process.name} (${process.pid}).`;
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
      ? `${selectedProcess().name} (${state.selectedPID})`
      : 'Choose a target';
    if (state.showingSetup) setSetupStatus(setupStatusText());
  }

  async function refreshProcesses() {
    const previous = $('#refreshProcesses').textContent;
    $('#refreshProcesses').disabled = true;
    $('#refreshProcesses').textContent = 'Refreshing…';
    setSetupStatus('Refreshing processes…');
    try {
      const response = await fetch('/api/processes');
      if (!response.ok) throw Error(await response.text());
      state.processes = parseProcesses(await response.arrayBuffer());
      if (state.selectedPID && !selectedProcess()) state.selectedPID = 0;
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
      !query || process.name.toLowerCase().includes(query) ||
      process.command.toLowerCase().includes(query) || String(process.pid).includes(query)
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
      row.title = process.command || process.name;
      row.innerHTML = '<span class="pid"></span><span class="name"></span>';
      row.firstChild.textContent = process.pid;
      row.lastChild.textContent = process.name;
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
      const response = await fetch('/api/profiles');
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
      row.lastChild.textContent = `pid ${run.pid}  ${run.duration.toFixed(2)} s`;
      row.onclick = () => loadProfile(run.id);
      return row;
    }));
    $('#traces').replaceChildren(...rows);
  }

  async function loadProfile(id, start, end) {
    state.selectedID = Number(id);
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
      state.profile = parseProfile(await response.arrayBuffer());
      state.selectedID = state.profile.id;
      state.range = [state.profile.start, state.profile.end];
      renderRuns();
      renderProfile();
    } catch (error) {
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

  function rebuildFlame() {
    const root = tree();
    const items = [];
    function walk(node, x, width, depth) {
      let cursor = x;
      const children = [...node.children.values()].sort((a, b) => b.count - a.count || a.frame.symbol.localeCompare(b.frame.symbol));
      for (const child of children) {
        const childWidth = width * child.count / Math.max(1, node.count);
        items.push({ node: child, x: cursor, width: childWidth, depth });
        walk(child, cursor, childWidth, depth + 1);
        cursor += childWidth;
      }
    }
    walk(root, 0, 1, 0);
    const flame = $('#flame');
    state.flameSource = state.profile;
    state.flameDepth = Math.max(0, ...items.map(item => item.depth)) + 1;
    flame.replaceChildren(...items.map(item => {
      const element = document.createElement('div');
      element.className = 'frame' + (item.node.frame.binary ? '' : ' single');
      element.style.left = item.x * 100 + '%';
      element.style.width = item.width * 100 + '%';
      element.style.top = item.depth * 31 + 'px';
      element.style.background = color(item.node.frame.binary || item.node.frame.symbol);
      element.innerHTML = '<b></b><small></small>';
      element.firstChild.textContent = item.node.frame.symbol;
      element.lastChild.textContent = item.node.frame.binary;
      element.title = `${item.node.frame.symbol}\n${item.node.frame.binary}\n${item.node.count} samples`;
      element.ondblclick = () => zoomAt(item.x + item.width / 2, 2);
      return element;
    }));
  }

  function layoutFlame() {
    if (!state.profile) return;
    const viewport = $('#flameViewport');
    const flame = $('#flame');
    flame.style.width = Math.max(1, state.zoom * viewport.clientWidth) + 'px';
    flame.style.height = Math.max(viewport.clientHeight, state.flameDepth * 31) + 'px';
  }

  function renderFlame() {
    if (!state.profile) return;
    if (state.flameSource !== state.profile) rebuildFlame();
    layoutFlame();
  }

  function setZoom(zoom, anchorFraction, anchorX) {
    if (!state.profile) return;
    const viewport = $('#flameViewport');
    const localX = anchorX == null ? viewport.clientWidth / 2 : anchorX;
    const contentFraction = anchorFraction == null
      ? (viewport.scrollLeft + localX) / (viewport.scrollWidth || 1)
      : anchorFraction;
    state.zoom = Math.max(1, Math.min(16, zoom));
    layoutFlame();
    viewport.scrollLeft = Math.max(0, contentFraction * viewport.scrollWidth - localX);
    $('#zoomReset').textContent = Math.round(state.zoom * 100) + '%';
  }

  function zoomAt(factor, multiplier) {
    if (!state.profile) return;
    const viewport = $('#flameViewport');
    setZoom(state.zoom * multiplier, factor, viewport.clientWidth / 2);
  }

  function flameAnchor(clientX) {
    const viewport = $('#flameViewport');
    const rect = viewport.getBoundingClientRect();
    const proposed = Number.isFinite(clientX) ? clientX - rect.left : viewport.clientWidth / 2;
    const x = Math.max(0, Math.min(viewport.clientWidth, proposed));
    return { x, fraction: (viewport.scrollLeft + x) / (viewport.scrollWidth || 1) };
  }

  function beginPinch(clientX, distance = 1) {
    clearTimeout(state.pinchEndTimer);
    state.pinchEndTimer = null;
    $('#flameViewport').classList.add('pinching');
    const anchor = flameAnchor(clientX);
    state.pinch = { zoom: state.zoom, anchor: anchor.fraction, x: anchor.x, distance };
  }

  function updatePinch(scale) {
    if (!state.pinch || !Number.isFinite(scale) || scale <= 0) return;
    setZoom(state.pinch.zoom * scale, state.pinch.anchor, state.pinch.x);
  }

  function endPinch() {
    state.pinch = null;
    clearTimeout(state.pinchEndTimer);
    state.pinchEndTimer = setTimeout(() => {
      $('#flameViewport').classList.remove('pinching');
      state.pinchEndTimer = null;
    }, 180);
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

  showSetup();
  Promise.all([refreshProcesses(), refreshPerf(), refreshRuns()]);
  setInterval(() => { if (state.recording) refreshRuns(); }, 1000);
})();
