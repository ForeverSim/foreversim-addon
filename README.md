# Forever Optimizer

The in-game addon for [ForeverSim](https://foreversim.app). It reads your character in the game
and gives you a text to paste on the site, which is how a character gets there until the game
has an official profile API.

This repository is the public copy of the addon: its source, every released zip, and their
fingerprints. It exists so that you can check what you download from the site against an
independent source.

## Install

1. Download `ForeverOptimizer-<version>.zip` from [foreversim.app/addon](https://foreversim.app/addon)
   or from [`dist/`](dist) here. They are the same file.
2. Extract it into your game's `Interface/AddOns` folder. You should end up with a folder named
   `ForeverOptimizer` in it.
3. In game, type `/optimizer`, copy the text from the window, and paste it on the site's
   dashboard.

## What it does, and what it cannot do

- It reads your own character: gear, talents, professions, stats and spellbook. In combat it
  notes how hard creatures hit you.
- It writes one file, its own saved settings, in the game's folder.
- It cannot send anything anywhere: the game does not let addons use the network. Nothing
  leaves your computer until you paste the text on the site yourself.
- It does not read your chat, your friends list or anything about your account.

The addon is plain Lua. Everything it does is in the files under
[`ForeverOptimizer/`](ForeverOptimizer); nothing is compiled or hidden.

## Check your download

[`SHA256SUMS`](SHA256SUMS) lists the SHA-256 fingerprint of every released zip and of every
source file. Compute the fingerprint of the zip you downloaded:

- Windows (PowerShell): `Get-FileHash ForeverOptimizer-<version>.zip -Algorithm SHA256`
- macOS and Linux: `shasum -a 256 ForeverOptimizer-<version>.zip`

It must be identical to the one in `SHA256SUMS` and to the one shown on
[foreversim.app/addon](https://foreversim.app/addon).

The zip is built reproducibly: the files of `ForeverOptimizer/` in name order, stored without
compression, with a fixed timestamp. Each version is a tag (`v0.1.0`, ...), and the history
shows what changed between them. A published version never changes.

## Not affiliated with Blizzard

ForeverSim is a fan project. World of Warcraft is a trademark of Blizzard Entertainment.
