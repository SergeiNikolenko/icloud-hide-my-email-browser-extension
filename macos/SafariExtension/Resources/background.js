// Shares the icloud.com session with the Hide My Email app whenever Safari's
// iCloud cookies change, so the app never has to read Safari's cookie store.
const DOMAINS = ["icloud.com", "icloud.com.cn"];
let pending;

async function share() {
  const cookies = (await Promise.all(DOMAINS.map((domain) => browser.cookies.getAll({ domain })))).flat();
  if (!cookies.some((cookie) => cookie.name.startsWith("X-APPLE-WEBAUTH"))) return;
  await browser.runtime.sendNativeMessage("com.nikolenko.HideMyEmail", {
    cookies: cookies.map(({ name, value, domain, path, expirationDate, secure }) => ({
      name,
      value,
      domain,
      path,
      expirationDate,
      secure,
    })),
  });
}

// iCloud rotates several cookies at once; send the settled set.
function scheduleShare() {
  clearTimeout(pending);
  pending = setTimeout(share, 1000);
}

browser.cookies.onChanged.addListener(({ cookie }) => {
  if (DOMAINS.some((domain) => cookie.domain.endsWith(domain))) scheduleShare();
});
browser.runtime.onInstalled.addListener(scheduleShare);
browser.runtime.onStartup.addListener(scheduleShare);
scheduleShare();
