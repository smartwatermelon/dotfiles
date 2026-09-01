// Finicky configuration — routes opened URLs to the right browser or Chrome app.
// Docs: https://github.com/johnste/finicky/wiki/Configuration-(v4)
//
// Deployed by install.sh to ~/.config/finicky/finicky.js, one of the paths
// Finicky 4 searches natively — so no ~/.finicky.js link is needed.
//
// Constraints that shape this file:
//
//   1. Finicky evaluates config in goja, a Go JavaScript engine — not Node.
//      There is no `process` global, so `process.env.HOME` throws a
//      ReferenceError that takes down the whole config.
//   2. Chrome PWAs ("Chrome Apps") live under a localized directory whose
//      on-disk name macOS may render differently than it displays. Addressing
//      one by bundle ID avoids depending on that path or the username at all,
//      and keeps working if the app moves.
//   3. A handler whose bundle ID is not installed does NOT fall back to
//      defaultBrowser: Finicky runs `open -b <id>`, `open` fails, and the URL
//      is dropped with "Failed to start browser" in the log. The config API
//      offers no "is this app installed" check (finicky.isAppRunning only
//      reports running apps), so list only PWAs that actually exist on this
//      machine. Bundle IDs are stable across machines for the same PWA — the
//      suffix is the Chrome web-app ID derived from the manifest — so a PWA
//      installed from the same origin elsewhere gets the same ID.
//
// Bundle IDs come from each app's own Info.plist:
//   defaults read ~/Applications/Chrome\ Apps.localized/<App>.app/Contents/Info.plist \
//     CFBundleIdentifier
//
// To test a change without opening anything:
//   /Applications/Finicky.app/Contents/MacOS/Finicky -config finicky/finicky.js -dry-run
//   (then `open https://github.com/...` from another shell and read the log)
//
// Anything with no matching handler falls through to defaultBrowser, so URLs
// that have no dedicated app need no rule here.

/** Builds a Chrome PWA browser target from its bundle ID. */
const chromeApp = (bundleId) => ({ name: bundleId, appType: "bundleId" });

const apps = {
  github: chromeApp("com.google.Chrome.app.mjoklplbddabcmpepnokjaffbmgbkkgg"),
};

export default {
  defaultBrowser: "Google Chrome",

  options: {
    // Finicky logs every opened URL to ~/Library/Logs/Finicky by default,
    // which accumulates a plaintext record of browsing — including alert,
    // ticket and PR links that carry account and incident identifiers.
    // Diagnostics still go to the console, so `Finicky -config <file>` from a
    // terminal remains available when a handler needs debugging.
    logRequests: false,
  },

  handlers: [
    // matchHostnames matches on host alone, so a bare https://github.com with
    // no trailing path is routed as well as any path beneath it. The regex
    // also catches subdomains such as gist.github.com and docs.github.com.
    {
      match: finicky.matchHostnames(["github.com", /\.github\.com$/]),
      browser: apps.github,
    },
  ],
};
