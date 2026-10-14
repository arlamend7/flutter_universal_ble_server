const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

// Runs the actual example script against a simulated GATT client connection.
// No browser UI, permission prompt or physical Bluetooth operation is performed.
test('browser client exchanges framed UTF-8 messages with matching GATT service', async () => {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, {textContent: '', value: '', disabled: false});
    return elements.get(id);
  };
  const writes = [];
  let notification;
  let disconnect;
  const receive = {writeValueWithResponse: async bytes => writes.push(Uint8Array.from(bytes))};
  const transmit = {
    addEventListener: (_, callback) => { notification = callback; },
    removeEventListener: () => {}, startNotifications: async () => {},
  };
  const name = {readValue: async () => new TextEncoder().encode('Servidor de teste')};
  const device = {
    addEventListener: (_, callback) => { disconnect = callback; },
    gatt: {connected: false,
      connect: async () => { device.gatt.connected = true; return {getPrimaryService: async () => ({
        getCharacteristic: async uuid => uuid.startsWith('d973f2e1') ? receive : uuid.startsWith('d973f2e2') ? transmit : name,
      })}; },
      disconnect: () => { device.gatt.connected = false; disconnect(); },
    },
  };
  const source = fs.readFileSync(path.join(__dirname, '../example/ble_client.html'), 'utf8').split('<script>')[1].split('</script>')[0];
  const context = vm.createContext({document: {getElementById: element}, navigator: {bluetooth: {requestDevice: async () => device}},
    TextEncoder, TextDecoder, Uint8Array, DataView, setTimeout, clearTimeout});
  vm.runInContext(source, context);
  await element('connect').onclick();
  assert.match(element('status').textContent, /Servidor de teste/);
  element('text').value = 'Olá do cliente, uma mensagem com vários fragmentos!';
  await element('send').onclick();
  assert.ok(writes.length > 1);
  const reconstructed = [];
  writes.forEach((bytes, index) => {
    assert.ok(bytes.length <= 20);
    const header = new DataView(bytes.buffer);
    assert.equal(header.getUint8(0), 1);
    assert.equal(header.getUint16(3, true), index);
    assert.equal(header.getUint16(5, true), writes.length);
    reconstructed.push(...bytes.slice(7));
    // Echo the exact wire frames back through the subscribed TX characteristic.
    notification({target: {value: new DataView(bytes.buffer)}});
  });
  assert.equal(new TextDecoder().decode(Uint8Array.from(reconstructed)), element('text').value);
  assert.match(element('log').textContent, /Servidor: Olá do cliente/);
  element('disconnect').onclick();
  assert.equal(element('send').disabled, true);
});
