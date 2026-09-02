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
//      one by its Chrome app ID avoids depending on that path or the username
//      at all, and keeps working if the app moves.
//   3. Launching a PWA by bundle ID (`open -b com.google.Chrome.app.<id> URL`)
//      does NOT deliver the URL: Chrome's app_mode_loader ignores it and opens
//      the app's start page, so a deep link to a pull request lands on bare
//      github.com. The only launch form that preserves the URL is Chrome
//      itself with `--app-id=<id>` plus
//      `--app-launch-url-for-shortcuts-menu-item=<url>`. A profile must be
//      given so Finicky adds `-n` and macOS starts a fresh Chrome process that
//      honors the args; without it the running Chrome is reused and the flags
//      are dropped. Recipe from the Finicky wiki (Configuration ideas), needs
//      Finicky >= 4.2.1.
//   4. A handler whose app is not installed does NOT fall back to
//      defaultBrowser — the URL is dropped. The config API offers no
//      "is this app installed" check (finicky.isAppRunning only reports
//      running apps), so list only PWAs that actually exist on this machine.
//      App IDs are stable across machines for the same PWA — Chrome derives
//      them from the manifest — so a PWA installed from the same origin
//      elsewhere gets the same ID.
//
// App IDs come from each app's own Info.plist:
//   defaults read ~/Applications/Chrome\ Apps.localized/<App>.app/Contents/Info.plist \
//     CrAppModeShortcutID
//
// To test a change without opening anything:
//   /Applications/Finicky.app/Contents/MacOS/Finicky -config finicky/finicky.js -dry-run
//   (then `open https://github.com/...` from another shell and read the log)
//
// Anything with no matching handler falls through to defaultBrowser, so URLs
// that have no dedicated app need no rule here.

// Chrome profile *directory* that owns the PWAs (not the display name, which
// is per-user). Finicky resolves the directory with a warning suggesting the
// display name; the directory is used deliberately so the config carries no
// account-specific string.
const CHROME_PROFILE_DIR = "Default";

/** Builds a browser function that opens `url` inside a Chrome PWA. */
const chromeApp = (appId) => (url) => ({
  name: "Google Chrome",
  profile: CHROME_PROFILE_DIR,
  args: [
    `--app-id=${appId}`,
    `--app-launch-url-for-shortcuts-menu-item=${url.toString()}`,
  ],
});

const apps = {
  github: chromeApp("mjoklplbddabcmpepnokjaffbmgbkkgg"),
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
    // no trailing path is routed as well as any path beneath it.
    //
    // Deliberately NOT matching subdomains (gist., docs., api.github.com):
    // Chrome only honors the launch URL when it is inside the PWA's scope
    // (github.com/). An out-of-scope URL opens the PWA at its start page and
    // the link is lost — verified with gist.github.com. Subdomains fall
    // through to Chrome instead.
    {
      match: finicky.matchHostnames(["github.com", "www.github.com"]),
      browser: apps.github,
    },
  ],
};
