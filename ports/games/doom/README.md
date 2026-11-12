# Doom

[doomgeneric](https://github.com/ozkl/doomgeneric) with a ZDOS platform file (`doomgeneric_zdos.c`), as `C:\GAMES\DOOM.APP`, playing [Freedoom: Phase 2](https://freedoom.github.io/) (`C:\DATA\DOOM\freedoom2.wad`).

```sh
ports/games/doom/build.sh             # all three CPUs
ports/games/doom/build.sh x86_64      # one or more: x86, x86_64, arm64
```

Sources: `$ZDOS_PORTS_SRC/doomgeneric` and `$ZDOS_PORTS_SRC/freedoom` (`../doomgeneric`, `../freedoom` when that variable is unset; `DOOMGENERIC=...`, `FREEDOOM=...`).

## Use

- Picture: 320 x 200 in 256 colors, scaled up to fill the screen. No sound.
- Keys as in DOS Doom: arrows move and turn, **Ctrl** fires, **Space** opens doors, **Shift** runs, **,** and **.** step sideways (strafe), or **Alt** with Left / Right; 1-7 pick weapons, Tab shows the map, Esc is the menu. Also **W** / **S** walk forward and back, **A** / **D** strafe; so these four letters can't be typed in Doom (cheat codes, savegame names). In QEMU, Ctrl+Alt is QEMU's own key for letting the mouse go.
- Mouse, as in DOS Doom: sideways turns, forward and back walks (`DOOM -novert`: only turns), left fires, right strafes while held, middle walks (not on UEFI). The speed is *Options -> Mouse sensitivity*. In QEMU, click into the window to give it the mouse; Ctrl+Alt+G lets it go.
- Held keys on UEFI: the firmware reports only presses, so a key counts as held while it repeats. A tap lasts 0.3 s (`DOOM -keyhold 150` for shorter); a held key moves, pauses until the keyboard repeats, then goes on. Ctrl, Shift and Alt count only with another key (Ctrl+Up fires while walking). The BIOS and metal editions know exactly which keys are held.
- `C:\DATA\DOOM` is its folder while it runs: Doom finds the WAD there and keeps its savegames in `.savegame\`; a `default.cfg` there is read (doomgeneric doesn't write one). Other WADs: `DOOM -iwad D:\DOOM2.WAD`. The current directory is put back when it ends.
