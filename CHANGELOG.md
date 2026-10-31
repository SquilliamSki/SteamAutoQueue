# Changelog

## 1.1.2
- Fix: updates in Scheduled were not being moved. Steam now sends its download list grouped per PC and moves Scheduled games with `ResumeAppUpdate(appid, clientId)`; the tool now does the same as Steam's own "move to top" button.
- After asking Steam to move updates, the tool checks they actually moved. It only reports what really moved, and the icon turns orange if Steam ignores the request.
- Fix: a run that queued nothing could be reported as "Queued 1 update(s)".

## 1.1.1
- First public release.
- The log no longer records Steam's command line when restarting Steam (it can contain login details).
- Update check points at this repository's GitHub Releases.

## 1.1.0
- Tray icon with an original icon: green = working, gray = paused, orange = needs attention.
- Double-click to queue now; right-click menu with pause/resume, settings, log, about and exit.
- Alerts when a Steam update seems to have broken the tool instead of failing silently.
- Weekly update check.

## 1.0.0
- Background helper that moves Scheduled Steam updates to Up Next at Steam start, daily, and every 30 minutes.
- Install / uninstall scripts and a plain-text settings file.
