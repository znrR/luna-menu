# luna-menu

Menüleisten-Apps für **Astropad Luna Display** im Mac-zu-Mac-Modus (Luna Secondary 5.3.9).

## Luna Menu – auf dem Secondary (Mac mini, iMac)

Steuert die App *Luna Secondary* über die Bedienungshilfen (Accessibility), denn sie hat keine Skript-Schnittstelle.

- **Turn to Monitor** – Luna Secondary starten und nach vorn holen
- **Allow from** – *Last used* (letzte IPs) oder *New IP …*: Es wird nur das letzte Oktett im eigenen Subnetz eingegeben. Luna Menu füllt den Dialog „Manual Connection“ aus und drückt „Connect“.
- **Settings …** – öffnet die Einstellungen von Luna Secondary
- **Sleep & Wake with Primary** – war der Mac beim Einschlafen des Primary dessen Bildschirm, geht sein Bildschirm aus (`pmset displaysleepnow`). Wacht der Primary auf, geht der Bildschirm wieder an und die Verbindung wird erneuert.
  - **Immer Bildschirm** (Standard auf dem iMac): Luna bleibt immer offen.
  - **Mac-Modus** (Standard auf dem Mac mini): Wird der Mac von Hand geweckt, während der Primary schläft, wird Luna Secondary sofort beendet. Der Mac bleibt dann Mac, bis man selbst umschaltet.
- Symbol: ein Bildschirm = frei, zwei Bildschirme = verbunden, Mond = Primary schläft

## Luna Primary – auf dem Primary (MacBook)

Hülle um *Luna Display*: Menüpunkte für „Manual Connect“ (zeigt die IP an) und die Einstellungen. Dazu kommt ein **Schlaf-Melder**: Der Primary meldet Einschlafen, Aufwachen und das Ausschalten seines Bildschirms per UDP-Broadcast an Port 44600:

```
LUNAMENU1 <alive|sleep|wake|screensleep|screenwake> <awake|screenoff|sleep> <hostname>
```

Alle 10 s kommt außerdem ein Lebenszeichen. Ohne Melder fragt der Secondary die Ports 44554–44556 des Primary ab. Das ist eine unsichere Ersatzlösung, denn ein Bonjour Sleep Proxy (z. B. Apple TV) kann den Primary dabei aufwecken.

## Bauen

```bash
./build.sh
```

- `Luna Menu.app` → `/Applications` (dieser Mac)
- `build/Luna Primary.app` (+ zip) – universal, ab macOS 10.15
- `build/iMac/Luna Menu.app` (+ zip) – Intel, ab macOS 10.15 (iMac late 2012)

Die Apps sind nur ad hoc signiert. Nach jedem Neubau muss man die Bedienungshilfen-Freigabe eventuell neu erteilen. Auf einem fremden Mac einmalig die Quarantäne entfernen: `xattr -dr com.apple.quarantine "/Applications/<App>.app"`.

Protokolle: `~/Library/Logs/LunaMenu.log` und `~/Library/Logs/LunaPrimary.log`.
