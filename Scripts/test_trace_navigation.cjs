const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../Resources/ProfileWeb/app.js'), 'utf8');
let location = new URL('https://profile.local/traces/2?mode=html');
const entries = [], loads = [];
let setups = 0;
const context = vm.createContext({ URL, Number,
  get location() { return location; },
  history: { pushState(_, __, url) { entries.push(url.href); location = new URL(url); } },
  loadProfile: id => loads.push(id), showSetup: () => setups++ });
vm.runInContext(source.slice(source.indexOf('  let profileLoadGeneration'), source.indexOf('  function showSetup')), context);
context.restoreTraceURL();
context.restoreTraceURL();
assert.deepEqual(loads, [2]);
context.updateTraceURL(3);
assert.equal(location.pathname, '/traces/3');
assert.equal(location.search, '?mode=html');
context.updateTraceURL(3);
assert.equal(entries.length, 1);
context.updateTraceURL(null);
assert.equal(location.pathname, '/');
location = new URL('https://profile.local/traces/2?mode=html');
context.restoreTraceURL();
assert.deepEqual(loads, [2, 2]);
location = new URL('https://profile.local/?mode=html');
context.restoreTraceURL();
assert.equal(setups, 1);
location = new URL('https://profile.local/traces/0');
context.restoreTraceURL();
assert.equal(setups, 2);
console.log('PASS trace deep links, duplicate event suppression, and history restoration');
