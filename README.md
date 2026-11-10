# luna-menu

Menu bar apps for **Astropad Luna Display** in Mac-to-Mac mode, where one Mac acts as the display of another.

**Main feature:** they solve the sleep and wake-up scenario between the primary and the secondary Mac. Luna Display on its own doesn't handle this: when the primary goes to sleep, the secondary keeps its screen on and sits on the waiting screen. When the primary wakes up again, nothing happens on the secondary.

With luna-menu:

- **Primary goes to sleep:** the secondary's display turns off, just like the regular macOS display sleep.
- **Primary wakes up:** the secondary's display turns back on and becomes the primary's display again.
- **You wake the secondary by hand while the primary sleeps:** depending on the mode, it either stays a display (Luna keeps waiting) or becomes a normal Mac again. In that case Luna Secondary quits right away and the Mac stays a Mac until you switch it back yourself.
- **Display sleep on the primary** (energy saver) is mirrored as well.

The primary reports its sleep and wake events itself, so the secondary doesn't have to guess.

## Luna Menu – on the Secondary (e.g. private Mac mini, iMac)

Remote control for the *Luna Secondary* app via Accessibility, since the app has no scripting interface.

- **Turn to Monitor** – launches Luna Secondary and brings it to the front.
- **Allow from** – *Last used* (recent primaries) or *New IP …*. For a new IP you only type the last octet within your own subnet. Luna Menu fills in Luna Secondary's “Manual Connection” dialog and presses “Connect”.
- **Settings …** – opens Luna Secondary's settings.
- **Sleep & Wake with Primary** – the sleep/wake coupling described above.
  - **Always a Display** (default on an iMac): Luna always stays open, and the Mac is only ever a display.
  - Off (default on a Mac mini), i.e. *Mac mode*: if you wake the Mac by hand while the primary sleeps, Luna Secondary quits immediately.
- **Open at Login**
- Menu bar icon: one display = free, two displays = connected, moon = primary asleep.

## Luna Primary – on the Primary (e.g. company-owned MacBook)

A wrapper around *Luna Display* with menu items for “Manual Connect” (shows the IP address) and its settings. It also contains the **sleep notifier**: it reports sleep, wake, and display sleep/wake via UDP broadcast on port 44600:

```
LUNAMENU1 <alive|sleep|wake|screensleep|screenwake> <awake|screenoff|sleep> <hostname>
```

It also sends a heartbeat every 10 s. Without Luna Primary, the secondary falls back to probing the primary's Luna ports (44554–44556). That is less reliable, and a Bonjour sleep proxy (e.g. an Apple TV) may wake the primary because of it.

## Building

Requires the Xcode Command Line Tools (`swiftc`); no Xcode project.

```bash
./build.sh
```

- `Luna Menu.app` → installed into `/Applications` (the Mac you build on)
- `build/Luna Primary.app` (+ zip) – universal, macOS 10.15+
- `build/iMac/Luna Menu.app` (+ zip) – Intel, macOS 10.15+ (e.g. iMac late 2012)

The apps are only ad-hoc signed:

- After every rebuild you may have to grant the Accessibility permission again (System Settings › Privacy & Security › Accessibility).
- On another Mac, remove the quarantine flag once: `xattr -dr com.apple.quarantine "/Applications/<App>.app"`

Logs: `~/Library/Logs/LunaMenu.log` and `~/Library/Logs/LunaPrimary.log`.

## Connection

Only tested via Ethernet, which I recommend. A Thunderbolt Bridge connection should also work, since the sleep notifier broadcasts on every IPv4 interface, but that is untested.

Tested with Luna Secondary / Luna Display 5.3.9. Not affiliated with Astropad.
