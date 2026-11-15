#include <emscripten.h>

/* Like browser_runtime/fixture_controls.h, keep controls in the test image. */
EM_JS(void, titan_net_test_publish, (), {
  const owner = Module['titanBrowserBridge'];
  const binding = owner.binding, release = owner.releaseSlot;
  const copy = Uint8Array.prototype.set;
  const large = 20 * 1024 * 1024;
  const marks = {takes: 0, high: 0, drains: 0,
    largeTakes: 0, largeReleased: 0, largeCopies: 0};
  owner.binding = function(pointer, length, state) {
    const result = binding.call(this, pointer, length, state);
    const name = new TextDecoder().decode(this.bytesAt(pointer, length));
    if (name === 'titan:websocket') {
      const source = result.value;
      const waiting = new WeakSet();
      result.value = function(op, ...args) {
        if (op === 'take') {
          marks.takes++;
          if (args[0].bytes?.byteLength === large) marks.largeTakes++;
        }
        const value = source(op, ...args);
        if (op === 'buffered' && value > 262144n) {
          marks.high++; waiting.add(args[0]);
          owner.options.bindings.ws_high(args[0].url);
        }
        if (op === 'buffered' && value >= 0n && value <= 65536n &&
            waiting.delete(args[0])) marks.drains++;
        return value;
      };
    }
    return result;
  };
  owner.releaseSlot = function(slot, generation) {
    const entry = this.slots.get(slot);
    const untaken = entry?.generation === generation && entry.units === 1 &&
      entry.value?.bytes?.byteLength === large;
    const result = release.call(this, slot, generation);
    if (untaken && !this.slots.has(slot)) marks.largeReleased++;
    return result;
  };
  Uint8Array.prototype.set = function(bytes, offset) {
    if (this.buffer === HEAPU8.buffer && bytes.byteLength === large) marks.largeCopies++;
    return copy.call(this, bytes, offset);
  };
  owner.options.bindings.__titanTest(Object.freeze({
    snapshot: () => ({...marks}),
    restore() {
      owner.binding = binding;
      owner.releaseSlot = release;
      Uint8Array.prototype.set = copy;
    }
  }));
});
