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
//
// Bundle IDs come from each app's own Info.plist:
//   defaults read ~/Applications/Chrome\ Apps.localized/<App>.app/Contents/Info.plist \
//     CFBundleIdentifier
//
// Anything with no matching handler falls through to defaultBrowser, so URLs
// that have no dedicated app need no rule here.

/** Builds a Chrome PWA browser target from its bundle ID. */
const chromeApp = (bundleId) => ({ name: bundleId, appType: "bundleId" });

const apps = {
  github: chromeApp("com.google.Chrome.app.mjoklplbddabcmpepnokjaffbmgbkkgg"),
  meet: chromeApp("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"),
  calendar: chromeApp("com.google.Chrome.app.kjbdgfilnfhdoflbpgamdcdgpehopbep"),
  gmail: chromeApp("com.google.Chrome.app.fmgjjmmmlfnkbppncabfkddbjimcfncm"),
  drive: chromeApp("com.google.Chrome.app.aghbiahbpaijignceidepookljebhfak"),
  docs: chromeApp("com.google.Chrome.app.mpnpojknpmmopombnjdcgaaiekajbnjb"),
  sheets: chromeApp("com.google.Chrome.app.fhihpiojkbmbpdjeoajapmgkhlnakfjf"),
  slides: chromeApp("com.google.Chrome.app.kefjledonklijopmnomlcbpllchaibag"),
  qualio: chromeApp("com.google.Chrome.app.ikpdgofpcddmjnkoffdccodkecpfaaig"),
  rippling: chromeApp("com.google.Chrome.app.jeogaiagchpljgopogffgchiggmahhif"),
  rootly: chromeApp("com.google.Chrome.app.bgaohalbodnpihominepoomjlllpgapa"),
  datadog: chromeApp("com.google.Chrome.app.hbjgmkjbceobnneiobpfpjddpfmjlmbk"),
};

/**
 * Matches one docs.google.com editor by its leading path segment.
 *
 * Docs, Sheets and Slides all share the docs.google.com hostname and differ
 * only by path, so matchHostnames cannot tell them apart. Any other path on
 * that host (Forms, a bare docs.google.com) matches nothing here and falls
 * through to defaultBrowser.
 */
const googleEditor = (segment) => (url) =>
  url.hostname === "docs.google.com" && url.pathname.startsWith(`/${segment}/`);

export default {
  defaultBrowser: "Google Chrome",
  handlers: [
    // matchHostnames matches on host alone, so a bare https://github.com with
    // no trailing path is routed as well as any path beneath it.
    {
      match: finicky.matchHostnames(["github.com", /\.github\.com$/]),
      browser: apps.github,
    },

    // ── Google Workspace ────────────────────────────────────
    { match: finicky.matchHostnames("meet.google.com"), browser: apps.meet },
    {
      match: finicky.matchHostnames("calendar.google.com"),
      browser: apps.calendar,
    },
    { match: finicky.matchHostnames("mail.google.com"), browser: apps.gmail },
    { match: finicky.matchHostnames("drive.google.com"), browser: apps.drive },
    { match: googleEditor("document"), browser: apps.docs },
    { match: googleEditor("spreadsheets"), browser: apps.sheets },
    { match: googleEditor("presentation"), browser: apps.slides },

    // ── Work tools ──────────────────────────────────────────
    { match: finicky.matchHostnames("app.qualio.com"), browser: apps.qualio },
    {
      match: finicky.matchHostnames("app.rippling.com"),
      browser: apps.rippling,
    },
    {
      match: finicky.matchHostnames(["rootly.com", /\.rootly\.com$/]),
      browser: apps.rootly,
    },
    {
      match: finicky.matchHostnames("app.datadoghq.com"),
      browser: apps.datadog,
    },
  ],
};
