// Finicky configuration — routes opened URLs to the right browser or Chrome app.
// Docs: https://github.com/johnste/finicky/wiki/Configuration
//
// Deployed by install.sh to ~/.config/finicky/finicky.js, which Finicky 4
// searches natively — so no ~/.finicky.js link is needed.
//
// Two constraints shape this file:
//
//   1. Finicky evaluates config in goja, a Go JavaScript engine — not Node.
//      There is no `process` global, so `process.env.HOME` throws a
//      ReferenceError that takes down the whole config.
//   2. Chrome PWAs ("Chrome Apps") live under a localized directory whose
//      on-disk name macOS may render differently than it displays. Addressing
//      one by bundle ID avoids depending on that path at all, and keeps working
//      if the app moves.
const githubApp = {
  name: "com.google.Chrome.app.mjoklplbddabcmpepnokjaffbmgbkkgg",
  appType: "bundleId",
};

export default {
  defaultBrowser: "Google Chrome",
  handlers: [
    {
      // matchHostnames matches on host alone, so a bare https://github.com is
      // covered as well as any path beneath it.
      match: finicky.matchHostnames(["github.com", /\.github\.com$/]),
      browser: githubApp,
    },
  ],
};
