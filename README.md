![Reaper banner: pixel-art Mac mini with a glowing red chip, the word Reaper, and a process list with one runaway bar](assets/banner.png)

# macos-process-reaper — `Reaper`

**A menu bar watch for the processes nobody remembers starting: sustained CPU and memory, plus the four broken states no threshold describes — zombie, orphan, windowless, not responding. It tells you; it never kills anything for you.** Needs no privileges, no daemon and no helper. Built on an M-series Mac and universal for Intel too.

[![build](https://github.com/beomwookang/macos-process-reaper/actions/workflows/build.yml/badge.svg)](https://github.com/beomwookang/macos-process-reaper/actions/workflows/build.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-black)](#requirements)
[![Language](https://img.shields.io/badge/Swift-AppKit%20only-orange)](app/)
[![Privileges](https://img.shields.io/badge/privileges-none-brightgreen)](#permissions)
[![Checks](https://img.shields.io/badge/checks-188-blue)](tests/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> A Mac that is hot, or slow, or out of memory usually has one process behind it,
> and it is rarely the one you are looking at. It is the headless browser a
> script left behind, the build that never finished, the viewer still redrawing
> at full tilt for a window you closed hours ago. Activity Monitor will show you
> that process — once you think to go and look. The point of this is that you
> do not have to think to look.

The mark in the menu bar is calm until a rule holds, and red when one does. If
it is calm, the rules you chose have nothing to report. If it is red, something
is named one click away, with the reason it was named and a button that ends it.

---

## Why this exists

This started inside `macos-fan-control`, a sibling project, where a process
watch was added because the fan is downstream of everything else: a machine at
100 °C with nothing visibly running has a process someone forgot about. But that
watch shipped behind a fan curve, could not be installed without a root daemon
and a `sudoers` rule, and only described processes that were *busy* — never ones
that were simply *broken*.

This is that watch on its own, with the parts it was missing: the broken states,
a mark whose only job is to change colour, and profiles so the thresholds are a
choice rather than a configuration exercise.

## What you get

| | |
|---|---|
| A mark that means one thing | Calm, amber while a rule is counting, red with a count once one holds |
| Four kinds of trouble | Sustained CPU, memory, uptime — and zombie, orphan, windowless, not responding |
| Profiles, then rules | Pick Quiet, Balanced or Aggressive; adjust the numbers underneath if you want to |
| Sustain, so a build is not a bug | A condition has to keep holding before anything is said about it |
| Detail when a row is not enough | Full command line, the chain of parents, threads, open files, a CPU trace |
| No privileges | No daemon, no helper, no `sudo`, no root. Installing is copying the app |
| Nothing automatic | A rule flags. A person decides. There is no setting that changes this |

## Requirements

| | |
|---|---|
| macOS | 13 or later |
| Hardware | Apple Silicon or Intel (the bundle is universal) |
| Build tools | Xcode command line tools (`swiftc`, `lipo`, `codesign`) |
| Privileges | None to run. `make install` writes to `/Applications`, which may ask for your password |

## Install

Build it on the machine you will run it on. The bundle is ad-hoc signed, so a
copy transferred from elsewhere picks up a quarantine flag and macOS refuses to
launch it.

```sh
git clone <this repo>
cd mac-process-reaper
make
make install          # copies build/Reaper.app to /Applications
open /Applications/Reaper.app
```

A mark appears in the menu bar. There is nothing else to set up. To have it come
back after a restart, use **Start at Login** in its menu.

To see what it is doing without opening anything:

```sh
/Applications/Reaper.app/Contents/MacOS/Reaper --diagnose
```

That prints the loaded profile, what the sampler found, what each rule made of
it, and which colour the mark would be. It is the answer to "why is it amber",
which a mark with three states and no text in two of them cannot give you.

The same text is a click away without a terminal: **About Reaper** in the menu
has a **Copy Diagnostics** button that puts it on the clipboard. If you are
filing an issue, paste it in — it says which profile is loaded and what the
rules made of your machine, which is otherwise the first thing anyone would have
to ask you.

## The mark

| | |
|---|---|
| Outline, in the menu bar's own ink | Nothing flagged |
| Amber | A rule's conditions are met and its sustain is still counting |
| Red, with a count | That many processes are flagged |

![The three states of the menu bar mark: a plain outlined chip, an amber chip, and a red chip with the number three beside it](assets/mark-states.png)

The chip fills from the bottom with how busy the machine is. That is not
decoration: eight flagged processes on an idle machine and eight on a saturated
one are different situations, and the mark should not read the same in both.

Amber is the state most watchdogs do not have. A rule that needs five minutes of
sustained CPU is right to wait five minutes, but while it is waiting the app
knows something you do not, and saying so costs nothing.

## The window

**Processes & Rules…** opens three bands, in the order you are likely to need
them.

**Profile** is the choice most people make once. Switching it replaces the rule
set whole, so a profile can never leave half of the last one behind. Its rules
start counting from the moment you switch: none of them has held for any time
yet.

**Rules** is that choice spelled out, editable in place. Each rule is a name,
four numbers and four states. Every condition that is set has to hold, and keep
holding for the rule's "for" time, before a process is flagged. Leave a number
empty to leave it out. Editing a condition restarts that rule's clock — the new
threshold has to earn its flag in its own right.

A rule that is switched on but cannot see what it needs says so, in orange, on
its own line. Silence from a watchdog is meant to mean "nothing is wrong", so a
rule that is quietly unable to look must not be silent.

**The table** is what the rules make of the machine right now: what is flagged,
then what is counting towards being flagged. Right-click a row for the two
signals and the parent; double-click it for everything else.

![The Processes window: the Aggressive profile selected, seven rules with their numbers and states, two of them marked inactive because the accessibility checks are off, and a table of flagged processes ending in Kill and Parent buttons](assets/window.png)

Two things in that picture are worth pointing at. The zombie's button says
**Parent**, not Kill, because a zombie cannot be signalled and its parent is the
only thing that clears it. And the two rules using the accessibility states say
**inactive**, with the reason, rather than sitting there flagging nothing.

Double-clicking a row opens everything the row had no space for:

![The detail window for a runaway process: a CPU trace rising past 500 per cent, its path, parent, start time, thread and open-file counts, the state explained in a sentence, the rule that flagged it, and its full command line](assets/detail.png)

### Profiles as shipped

| Profile | What it is for |
|---|---|
| **Quiet** | Only what is unmistakable: 500% for ten minutes, or 8 GB for five |
| **Balanced** | Runaways, memory hogs, long-running busy processes, and orphans burning a core. Needs no permissions |
| **Aggressive** | The same, sooner, plus zombies and the two states that need Accessibility |

**Restore Profiles** puts each shipped profile back as shipped — replacing one
you edited, re-adding one you deleted — and leaves profiles of your own alone.
They are matched on identity, not name, so renaming one does not turn it into a
second one.

## The four states, and what they can actually tell you

Three numbers describe a process that is working too hard. These four describe
one that is broken, and they are worth being precise about, because two of them
are harder to know than they look.

### zombie

Dead already, and not yet collected by its parent. It holds no CPU and no
memory, cannot be signalled, and has no path or command line left — the address
space those would be read from is gone. **A zombie is almost never a problem**,
and it is listed so it can be explained rather than because it costs anything. A
machine accumulating thousands of them has a parent process with a bug, which is
the thing worth knowing.

Because a zombie cannot be signalled, its row's button offers its **parent**
instead, named in the tooltip: ending the parent is what collects the child. A
zombie whose parent is something macOS ships is a dead end, and the button says
so.

Worth recording, since it cost an afternoon: the kernel refuses to describe a
zombie through `proc_pidinfo`. Both `PROC_PIDTBSDINFO` and
`PROC_PIDT_SHORTBSDINFO` return `ESRCH` for a pid `proc_listallpids` has just
handed over, because both read the task and the task is gone. `sysctl` with
`KERN_PROC_PID` still answers from the process table entry, which is how `ps`
manages to print them at all.

### orphan

Adopted by launchd, and not part of macOS.

The textbook definition is `ppid == 1`, and on macOS that is close to useless on
its own: launchd is the direct parent of every LaunchAgent and every app the Dock
starts, so it reads as the normal state rather than as a process that lost its
parent. Measured on one machine: **438 of 496** of the user's processes had ppid
1. Excluding what macOS itself ships brings that to 40, which is a signal worth
combining with a threshold — and why the shipped orphan rules also ask for a full
core and an hour of uptime. Without that they flag every crashpad handler and XPC
service launchd legitimately parents.

A controlling terminal looked like the better discriminator: a job left behind by
a shell keeps its tty, where an agent never had one. It is not, because the tty
is revoked when the terminal goes, so it reads as `NODEV` for exactly the
processes it was meant to find. Measured: zero of the 438.

### no window

An app meant to have a window, with none on screen. This is the shape of a
viewer still redrawing for a window closed hours ago, and it is the state that
needs Accessibility.

`CGWindowListCopyWindowInfo` needs no permission at all and cannot answer the
question, either way round. Asked for on-screen windows only, it reports nothing
for every app whose windows are on another Space or minimised — measured: Chrome,
Finder, Cursor and Preview all read as having zero windows while plainly having
several. Asked for all windows, it keeps reporting windows an app has already
closed — measured: TextEdit with every document closed still listed the two it
used to have, unchanged, indefinitely. One would flag apps that are fine; the
other would never flag anything. The accessibility window list tracks what an app
actually has, so it is the only source worth using.

### not responding

Its main thread is not draining its event queue. This is the state the spinning
cursor is showing you, and it is read by asking the app for its windows with a
quarter-second deadline: a hung app cannot reply, and the request times out. An
app that *does* reply has told you how many windows it has in the same breath,
which is why one call serves both states and one permission covers both.

## Permissions

Reaper asks for nothing to do most of its job, and asks for one thing to do the
rest.

**Nothing** is needed for CPU, memory, uptime, zombie and orphan. The Quiet and
Balanced profiles use only these, so they work on a machine that has granted
nothing at all.

**Accessibility** is needed for `no window` and `not responding`, for the reasons
above. It is off until you turn on **Inspect Apps for Windows & Hangs** in the
menu, and macOS will ask when you do. Until then, rules using those two states
say they are inactive rather than flagging nothing in silence.

Two things to know about it:

- The bundle is ad-hoc signed, so **rebuilding changes its signature and macOS
  may drop the permission**. Re-grant it after `make`, or leave the switch off.
- The window count from the accessibility list has not been verified end to end
  in this repo, because doing so needs the grant, which needs a person in System
  Settings. The path with the permission denied *is* covered: it reports why
  rather than guessing, and the suite checks that.

**Other people's processes** are never listed. macOS refuses their readings
without root and refuses the signal too, so a process this app could not judge
is also one it could not end — nothing usable is lost by leaving them out, and
nothing has to run as root to leave them out.

## What it does not do, and why

- **Kill anything on its own.** A rule flags; a person decides. There is no
  setting for this. An app that ended processes by itself would be a worse
  version of the problem it exists to find.
- **Notify.** The mark is the alert. A notification for something already red in
  the corner of the screen is noise.
- **Per-app whitelists or per-app limits.** Profiles cover the case this was
  built for. App Tamer's per-app model is a bigger idea than this needs yet.
- **Throttle or suspend.** It watches and reports. Holding a process at 20% of a
  core is a different program.
- **Run as root**, install a daemon, a helper, or a `sudoers` rule.

## Overhead

Every tick walks every pid, reads BSD info and rusage for each, and evaluates the
rules. Measured on an M-series Mac with about 490 processes running:

| | |
|---|---|
| CPU, 5 s poll | **0.53–0.56% of one core** (two runs, 100 s and 180 s) |
| One sample | **3.9 ms** to read 484 processes, plus 1.6 ms to evaluate seven rules |
| Resident | **45 MB**, nearly all of it AppKit |
| Machine | 498 processes owned by the user, 789 in total, 10 cores |

Where the time in a sample goes, measured per pass over the same pid list:
`proc_listallpids` under 0.1 ms, `PROC_PIDTBSDINFO` 0.8 ms for all 786 pids,
`proc_pid_rusage` 1.0 ms, `proc_pidpath` 1.2 ms. Reading the system load and the
GPU is under 0.1 ms; drawing the mark is about 1.4 ms on the pass that has to
lay out a digit.

**Sample Every** in the menu sets the interval: 2, 5, 10 or 30 seconds. Five is
the default. A longer interval is a cheaper and smoother CPU reading — the figure
is the average over one interval — and a coarser sustain clock. Turning on
Inspect Apps adds one accessibility round trip per app, with a quarter-second
ceiling each.

## Working on it

```sh
make            # build/Reaper.app, universal, ad-hoc signed
make test       # ./build/tests -- logic and drawing, no windows, 188 checks
make app        # the bundle only
make install    # copy to /Applications
make uninstall  # remove the app and the login item
make clean
```

Tests are a plain executable with a hand-rolled `check` closure — no XCTest, so
the whole project builds with `swiftc` and nothing else. Time is injected:
`evaluate(_:rules:now:)` takes `now` as a parameter precisely so a five-minute
sustain is checked in five lines rather than five minutes. The environment is
injected too: `sample(_ ctx:)` takes the window and responsiveness facts rather
than looking them up, so the rules can be checked on a machine with no window
server and no accessibility grant.

What the suite does **not** cover: the two windows are never opened, because a
headless runner cannot open one. Their layout is looked at by hand. The
accessibility window count is not covered either, for the reason given above.

### Producing each state by hand

The four states cannot be unit-tested end to end, so each has a recipe.

| State | How to make one |
|---|---|
| Runaway CPU | A process with several spinning threads. One `while :; do :; done` is only one core — 100%, below every shipped threshold, and correctly so |
| Memory hog | A script that allocates a few GB and sleeps |
| Zombie | A parent that forks, lets the child exit, and then sleeps without calling `wait()` |
| Orphan | `zsh -c '(sleep 900 &)'` — the `sleep` is reparented to launchd |
| No window | Open an app, close every window, leave it running |
| Not responding | `kill -STOP <pid>` of a GUI app: it stops answering its accessibility port |

`--diagnose` after each one is the quickest way to see what the sampler made of
it.

## Uninstall

```sh
make uninstall                     # the app, and the login item
defaults delete com.local.reaper   # the profiles and settings
```

## What it touches on your system

There is not much, which is the point.

| Path | What it is |
|---|---|
| `/Applications/Reaper.app` | The app. Written by `make install`, removed by `make uninstall` |
| `~/Library/LaunchAgents/com.local.reaper.plist` | The login item, written only if you turn it on. It runs `open -a Reaper` and nothing else |
| `com.local.reaper` in your user defaults | Profiles, the active profile, poll interval, the Inspect Apps switch |

No daemon, no LaunchDaemon, no `/etc/sudoers.d` entry, no helper binary, nothing
owned by root, and nothing written outside your home directory except the bundle
itself.

## License

MIT. See [LICENSE](LICENSE).
