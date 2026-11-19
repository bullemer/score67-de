// Score67 Web Bluetooth bridge (Chrome on Android/desktop). Up to two LED
// displays ("slots" 0 and 1) receive text frames from the control center.
(() => {
  // Serial-over-BLE profiles used by common LED controllers and DIY boards.
  const PROFILES = [
    {service: '6e400001-b5a3-f393-e0a9-e50e24dcca9e', write: '6e400002-b5a3-f393-e0a9-e50e24dcca9e'}, // Nordic UART
    {service: 0xffe0, write: 0xffe1}, // HM-10, BT05, JDY-08 …
    {service: 0xfff0, write: 0xfff2}, // many LED signs
    {service: 0xfee7, write: 0xfec7},
  ];
  const slots = {};
  const listened = new WeakSet();
  const encoder = new TextEncoder();

  async function findCharacteristic(server) {
    for (const profile of PROFILES) {
      try {
        const service = await server.getPrimaryService(profile.service);
        return await service.getCharacteristic(profile.write);
      } catch { /* try the next profile */ }
    }
    for (const service of await server.getPrimaryServices()) {
      for (const c of await service.getCharacteristics()) {
        if (c.properties.writeWithoutResponse || c.properties.write) return c;
      }
    }
    return null;
  }

  async function attach(slot, device) {
    const server = await device.gatt.connect();
    const characteristic = await findCharacteristic(server);
    if (!characteristic) { device.gatt.disconnect(); throw new Error('no_writable_characteristic'); }
    const entry = slots[slot] || {};
    if (entry.device && entry.device !== device) {
      try { entry.device.gatt.disconnect(); } catch { /* already gone */ }
    }
    Object.assign(entry, {device, characteristic, state: 'connected', queue: entry.queue || Promise.resolve(), wanted: true});
    slots[slot] = entry;
    // Once per device, not per slot: a second panel paired into the same slot
    // needs its own listener, and only the slot's current panel may reconnect.
    if (!listened.has(device)) {
      listened.add(device);
      device.addEventListener('gattserverdisconnected', () => {
        if (slots[slot] && slots[slot].device === device) reconnect(slot);
      });
    }
    return device.name || 'Bluetooth';
  }

  async function reconnect(slot) {
    const entry = slots[slot];
    if (!entry || !entry.wanted || entry.reconnecting) return;
    entry.reconnecting = true;
    entry.state = 'reconnecting';
    const device = entry.device;
    // A panel switched off at half-time comes back by itself: keep trying
    // (every 15 s after the first attempts) until it is removed by hand.
    try {
      for (let delay = 500; entry.wanted && entry.device === device; delay = Math.min(delay * 2, 15000)) {
        await new Promise(resolve => setTimeout(resolve, delay));
        if (!entry.wanted || entry.device !== device) return;
        try { await attach(slot, device); return; } catch { /* keep trying */ }
      }
    } finally {
      entry.reconnecting = false;
    }
  }

  async function connect(slot) {
    if (!navigator.bluetooth) throw new Error('unsupported');
    const device = await navigator.bluetooth.requestDevice({
      acceptAllDevices: true,
      optionalServices: PROFILES.map(p => p.service),
    });
    return attach(slot, device);
  }

  function write(slot, text) {
    const entry = slots[slot];
    if (!entry || entry.state !== 'connected') return Promise.resolve(false);
    const bytes = encoder.encode(text);
    // One GATT operation at a time; BLE packets carry 20 bytes by default.
    entry.queue = entry.queue.then(async () => {
      for (let i = 0; i < bytes.length; i += 20) {
        const chunk = bytes.slice(i, i + 20);
        const c = entry.characteristic;
        if (c.properties.writeWithoutResponse && c.writeValueWithoutResponse) await c.writeValueWithoutResponse(chunk);
        else await c.writeValue(chunk);
      }
      return true;
    }).catch(() => false);
    return entry.queue;
  }

  function disconnect(slot) {
    const entry = slots[slot];
    if (!entry) return;
    entry.wanted = false;
    entry.state = 'disconnected';
    try { entry.device.gatt.disconnect(); } catch { /* already gone */ }
  }

  window.score67Ble = {
    supported: () => !!navigator.bluetooth,
    connect: slot => connect(slot),
    write: (slot, text) => write(slot, text),
    disconnect: slot => disconnect(slot),
    status: slot => (slots[slot] && slots[slot].state) || 'disconnected',
    name: slot => (slots[slot] && slots[slot].device && slots[slot].device.name) || '',
  };
})();
