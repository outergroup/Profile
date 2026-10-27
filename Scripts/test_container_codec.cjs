const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../Resources/ProfileWeb/app.js'), 'utf8');
const context = vm.createContext({TextDecoder, DataView, Uint8Array, Number});
vm.runInContext('const decoder = new TextDecoder();' + source.slice(source.indexOf('  const u32'), source.indexOf('  function parseProfile')), context);
const bytes = fs.readFileSync(process.argv[2]);
const processes = context.parseProcesses(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
const selected = processes.find(row => row.pid === Number(global.process.argv[3]));
assert(selected); assert.equal(selected.container, 'Host'); assert.equal(selected.containerID, 'host'); assert.equal(selected.localPID, selected.pid);
console.log('PASS actual browser process decoder with container fields');
