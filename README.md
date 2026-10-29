# Xattred

**AI-developed.** A tiny native macOS utility with a white-on-black X, a menu-bar home, and a big, explicit toggle for clearing app extended attributes. macOS 13+; no dependencies or analytics.

## Build & use

With Apple’s Swift command-line tools installed:

```sh
bash /Users/user/Documents/xattred/scripts/build.sh
open /Users/user/Documents/xattred/dist/Xattred.app
```

Choose **Choose App…**, select an app you trust, and enable **Clear extended attributes**. Settings include open at login, hiding the menu-bar icon, and a configurable GitHub repository link. Reopen Xattred in Finder to reach settings when hidden. No repository URL was supplied, so the GitHub button stays disabled until configured.

**Nothing outside `/Users/user/Documents/xattred/Inbox` is watched.** New quarantined apps placed directly there trigger review after two stable scans. Existing apps are ignored on launch. Copy detection is a heuristic (up to six minutes of settling checks); use manual selection after longer copies. Manual selection inspects only the selected app and never adds watches. The Inbox path is deliberately fixed to this project.

**Caution:** clearing runs `xattr -crs` (recursive clear, without following symlinks). It permanently removes **all** extended attributes, including quarantine; it does not make software safe. No automatic changes, admin escalation, or automatic app launching. Permission errors may leave attributes partially cleared.

Tests: `bash /Users/user/Documents/xattred/scripts/test.sh`. Builds are locally ad-hoc signed, not notarized. Reliable login registration may require a stable installed app location and approval in macOS Login Items; public distribution requires Developer ID signing/notarization.