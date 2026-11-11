# ForeverSim

The in-game addon for [ForeverSim](https://foreversim.app). It reads your character in the game
and gives you a text to paste on the site, which is how a character gets there until the game
has an official profile API.

Its companion, **ForeverSim Macros**, is a macro maker: pick what a macro should do, read in
plain words what it does, and copy it into the game's macro window. It explains how macros work
for new players, opens from a button on the screen or from Options, AddOns, and never makes or
runs a macro itself. Its source is under [`ForeverSimMacros/`](ForeverSimMacros).

This repository is the public copy of both addons: their source, every released zip, and their
fingerprints. It exists so that you can check what you download from the site against an
independent source.

## Install

1. Download `ForeverSim-<version>.zip` from [foreversim.app/addon](https://foreversim.app/addon)
   or from [`dist/`](dist) here. They are the same file.
2. Extract it into your game's `Interface/AddOns` folder. You should end up with a folder named
   `ForeverSim` in it.
3. In game, type `/foreversim`, copy the text from the window, and paste it on the site's
   dashboard.

## What it does, and what it cannot do

- It reads your own character (gear, talents, professions, stats and spellbook) when you type
  `/foreversim`, and gives you the text to paste on the site.
- In a group it shows a threat window: every enemy fighting your group, who it is on, and a
  warning when one turns to you (or, if you tank, away from you). `/foreversim panel` has its
  settings, your statistics and help. It records nothing for the site.
- It writes one file, its own saved settings, in the game's folder.
- It cannot send anything anywhere: the game does not let addons use the network. Nothing
  leaves your computer until you paste the text on the site yourself.
- It does not read your chat, your friends list or anything about your account.

The addon is plain Lua. Everything it does is in the files under
[`ForeverSim/`](ForeverSim); nothing is compiled or hidden.

## Check your download

[`SHA256SUMS`](SHA256SUMS) lists the SHA-256 fingerprint of every released zip and of every
source file. Compute the fingerprint of the zip you downloaded:

- Windows (PowerShell): `Get-FileHash ForeverSim-<version>.zip -Algorithm SHA256`
- macOS and Linux: `shasum -a 256 ForeverSim-<version>.zip`

It must be identical to the one in `SHA256SUMS` and to the one shown on
[foreversim.app/addon](https://foreversim.app/addon).

The zip is built reproducibly: the files of `ForeverSim/` in name order, stored without
compression, with a fixed timestamp. Each ForeverSim version is a tag (`v0.4.1`, ...), each
ForeverSim Macros version one too (`macros-v0.1.0`, ...), and the history shows what changed
between them. A published version never changes. (`ForeverOptimizer-*.zip` in `dist/` are the
addon's releases from before it was renamed ForeverSim.)

## Not affiliated with Blizzard

ForeverSim is a fan project. World of Warcraft is a trademark of Blizzard Entertainment.
