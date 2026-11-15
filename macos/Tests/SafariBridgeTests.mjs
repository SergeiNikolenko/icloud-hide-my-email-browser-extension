import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setImmediate } from "node:timers/promises";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../SafariExtension/Resources/background.js", import.meta.url), "utf8");

function bridge({ reply = { ok: true }, reject = false, signedIn = true } = {}) {
  const events = {};
  const calls = [];
  const warnings = [];
  let scheduled;
  const event = (name) => ({ addListener: (listener) => { events[name] = listener; } });
  const browser = {
    cookies: {
      onChanged: event("cookies"),
      getAll: async ({ domain }) => signedIn && domain === "icloud.com" ? [{
        name: "X-APPLE-WEBAUTH-TOKEN", value: "test-session", domain: ".icloud.com", path: "/", secure: true,
      }] : [],
    },
    runtime: {
      onInstalled: event("installed"),
      onStartup: event("startup"),
      sendNativeMessage: async (...args) => {
        calls.push(args);
        if (reject) throw new Error("sensitive native error");
        return reply;
      },
    },
    permissions: { onAdded: event("permission") },
    action: { onClicked: event("click") },
  };
  vm.runInNewContext(source, {
    browser,
    console: { warn: (message) => warnings.push(message) },
    clearTimeout: () => { scheduled = undefined; },
    setTimeout: (callback) => { scheduled = callback; return 1; },
  });
  return {
    events, calls, warnings,
    async flush() {
      const callback = scheduled;
      scheduled = undefined;
      callback?.();
      await setImmediate();
    },
  };
}

test("shares the current session after permission grant and toolbar click", async () => {
  const app = bridge();
  await app.flush();
  assert.equal(app.calls.length, 1);
  app.events.permission({ origins: ["https://*.icloud.com/*"] });
  await app.flush();
  app.events.click();
  await app.flush();
  assert.equal(app.calls.length, 3);
  assert.equal(app.calls[2][0], "com.nikolenko.HideMyEmail");
  assert.equal(app.calls[2][1].cookies[0].value, "test-session");
  assert.deepEqual(app.warnings, []);
});

test("settles cookie changes into one handoff", async () => {
  const app = bridge();
  await app.flush();
  for (let i = 0; i < 3; i++) app.events.cookies({ cookie: { domain: ".icloud.com" } });
  await app.flush();
  assert.equal(app.calls.length, 2);
  app.events.cookies({ cookie: { domain: ".example.com" } });
  await app.flush();
  assert.equal(app.calls.length, 2);
});

for (const [name, options] of [
  ["native rejection", { reject: true }],
  ["failed save", { reply: { ok: false } }],
  ["missing acknowledgment", { reply: null }],
]) {
  test(`handles ${name} without leaking native errors or cookies`, async () => {
    const app = bridge(options);
    await app.flush();
    assert.deepEqual(app.warnings, ["Hide My Email could not share the iCloud session."]);
    app.events.click();
    await app.flush();
    assert.equal(app.calls.length, 2);
  });
}

test("does not hand off an unsigned session", async () => {
  const app = bridge({ signedIn: false });
  await app.flush();
  assert.equal(app.calls.length, 0);
  assert.deepEqual(app.warnings, []);
});
