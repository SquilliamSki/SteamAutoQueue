STEAM AUTO QUEUE
================

An independent tool. Not made by, affiliated with, or endorsed by
Valve or Steam.

Home page, new versions and bug reports:
https://github.com/SquilliamSki/SteamAutoQueue

The problem
-----------
Steam puts many game updates in "Scheduled" and waits for a quiet time
(often overnight) to download them. If your PC is off or asleep then,
they just sit there until you click each one by hand.

What this does
--------------
A small tray icon (near the clock) that moves everything from
"Scheduled" into "Up Next" so Steam downloads it right away.
Set it up once and forget it.


SETUP (about 1 minute)
----------------------
1. Unzip this folder anywhere.
2. Double-click  Install.cmd
3. If Steam is open, say Y when it offers to restart Steam once.

That's it. You can delete the unzipped folder afterwards.

If Windows shows "Windows protected your PC", click "More info" ->
"Run anyway". (It appears because the file came from the internet.)
No admin rights are needed.

Don't see the icon? Click the ^ arrow by the clock and drag the green
download-arrow icon onto the taskbar so it always shows.


THE TRAY ICON
-------------
Its color tells you how things are:
   Green   working normally
   Gray    paused
   Orange  needs attention (hover or right-click to see why)

Double-click it to queue everything right now.
Right-click it for:
   Queue updates now
   Pause / Resume automatic queueing
   Open Steam downloads
   Settings
   View log
   Check for updates
   About
   Exit (it starts again at your next login)

By default, every time Steam starts it waits a minute, then queues all
Scheduled updates, and checks again every 30 minutes while Steam is
open. You'll see a small notification when it queues something.


CHANGING HOW IT WORKS
---------------------
Right-click the icon -> Settings. Every option is explained in the file.
Common tweaks:

  Only once a day at 7pm, not at startup:
      RunWhenSteamStarts = false
      DailyTime = 19:00

  Daily at 4am, and open Steam by itself if it's closed:
      DailyTime = 04:00
      StartSteamForDailyRun = true
      (Your PC still has to be awake at 4am for that.)

  Never touch a certain game:
      ExcludeAppIds = 570, 730

  Try it out without changing anything:
      TestMode = true   (then check the log)

Save the file and the change takes effect within seconds.


TURNING IT OFF / REMOVING IT
----------------------------
  For a while:   right-click the icon -> Pause automatic queueing
  Until login:   right-click the icon -> Exit
  For good:      Start Menu -> "Uninstall Steam Auto Queue"
                 (or double-click Uninstall.cmd in the download folder)

Uninstall removes everything listed under "What the installer changes".


UPDATING
--------
Download the new version from the Releases page (link above) and run
its Install.cmd. Your settings are kept. The tray icon checks once a
week and tells you when a new version is out.

If a Steam update breaks this tool, the icon turns orange and says so.
Nothing bad happens - Steam just goes back to its normal scheduling
until there's a fix.


HOW IT WORKS (for the curious)
------------------------------
Steam's window is built on Chromium, and Steam has a developer switch
(-cef-enable-debugging) that lets programs on this PC talk to it. The
installer turns that switch on, and the helper uses it to call the same
"queue this update" action you'd get by clicking each game's download
button. Nothing is downloaded from anywhere else, and Steam's own files
are not modified.

What the installer changes:
  - Adds a small marker file (.cef-enable-remote-debugging) in your
    Steam folder, and adds the switch to Steam's "start with Windows"
    entry, so the switch is on whenever Steam runs.
  - Adds a Task Scheduler entry called "Steam Auto Queue" that starts
    the tray icon at login.
  - Copies itself to  %LOCALAPPDATA%\SteamAutoQueue
  - Adds Start Menu shortcuts.

Resource use: one small PowerShell process, roughly 60-100 MB of
memory and effectively no CPU (it checks in every 15 seconds).

Worth knowing:
  - The switch only listens on this PC (127.0.0.1), not your network.
    But while it's on, any program already running on your PC could
    also control Steam through it. That's the same trade-off every
    Steam UI mod (Millennium, Decky, etc.) makes. If that's not OK
    for you, don't install this.
  - This uses Steam's internal, undocumented functions, so a future
    Steam update could break it (see UPDATING above).
  - If Steam gets started without the switch (for example after Steam
    updates itself), the helper restarts Steam once right after it
    opens to turn the switch back on. It never does this while a game
    is running. Set AutoFixSteam = false to stop that.


TROUBLESHOOTING
---------------
Icon is orange: "Steam was opened without the helper switch"
    Double-click the icon and say Yes to restart Steam, or quit Steam
    fully (Steam menu -> Exit) and open it again.

Icon is orange: "Steam is not responding the way this tool expects"
    A Steam update probably changed something. Check for a new version.

No icon at all
    Check the ^ overflow area by the clock. Still nothing? Start Menu
    -> "Steam Auto Queue" starts it. Running Install.cmd again is
    always safe and keeps your settings.

Some games stay in Scheduled
    Check ExcludeAppIds in settings. Updates in "Unscheduled" are left
    alone unless QueueUnscheduledToo = true.
