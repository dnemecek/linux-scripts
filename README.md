# linux-scripts

Rodina shell skriptů pro správu Linuxu. Cílová distribuce je Rocky Linux.

## Obsah

| Skript | Účel |
|---|---|
| `bin/claude-rc.sh` | Claude Code Remote Control server jako služba systemd: sessions z mobilu nebo claude.ai/code. Název `<počítač> - <složka>`. Config `claude-rc.conf` (vzor `bin/claude-rc.conf.example`). Viz níže. |

Rozpracované úkoly jsou v `TODO.md`.

## claude-rc jako služba (systemd)

Server běží nad složkou serveru (obsahuje workspaces, výchozí `~/Repos` uživatele služby).
`install` vytvoří systémovou jednotku `/etc/systemd/system/<unitPrefix>-<složka>.service`
s `User=<serviceUser>`; systemd pak server spustí po každém startu systému (bez přihlášení)
a po pádu (pauza 30 s). Při každém startu systemd volá `claude-rc.sh run DIR`, který ověří
složku serveru a pak se nahradí procesem `claude remote-control`.

### Instalace (Rocky Linux 9)

Požadavky: systemd, 4 GB RAM, předplatné claude.ai (Pro, Max, Team nebo Enterprise; API klíč
Remote Control nepodporuje). V LXC kontejneru zapnout `nesting=1`, jinak systemd neizoluje služby.

Jako root na čistém serveru:

```bash
curl -fsSL https://raw.githubusercontent.com/dnemecek/linux-scripts/main/bin/claude-rc.sh | bash -s setup
```

`setup` postupně:

1. nasadí skript do `/usr/local/bin/claude-rc.sh` a config `claude-rc.conf` vedle něj (`serviceUser=claude`),
2. nainstaluje `git` (sessions s ním pracují v repozitářích),
3. vytvoří uživatele služby `claude` a složku serveru `~/Repos`,
4. nainstaluje Claude Code pro uživatele služby (nativní instalátor, `~/.local/bin/claude`, aktualizuje se sám),
5. spustí `claude auth login`: otevřít vypsanou URL v prohlížeči na jiném počítači, přihlásit se
   účtem claude.ai a kód vložit zpět do terminálu,
6. spustí server v popředí (`init`): odpovědět `y` na důvěru složky a na „Enable Remote Control?“,
   po výpisu běžícího serveru Ctrl+C,
7. nainstaluje a spustí službu (`install`) a vypíše `status`.

Hotové kroky přeskočí; jiný uživatel služby: `CLAUDE_RC_USER=jmeno` před `bash` (proměnná pro
celou pipe: `curl … | CLAUDE_RC_USER=jmeno bash -s setup`). Session `<hostName> - Repos` je pak
v seznamu na claude.ai/code a v aplikaci Claude.

### Provoz

```bash
claude-rc.sh status                  # stav, PID, počet restartů; chybějící složku označí MISSING
claude-rc.sh restart | stop | start  # root (nebo sudo)
claude-rc.sh uninstall               # zrušení služby, root (nebo sudo)
journalctl -u claude-rc-Repos        # log serveru (root nebo skupina systemd-journal)
```

Aktualizace skriptu: znovu příkaz z Instalace (stáhne aktuální skript a přeinstaluje službu).

### Poznámky

- Config: řádky `klíč=hodnota` (`serverDir`, `hostName`, `unitPrefix`, `serviceUser`), soubor se
  nespouští; `~` na začátku cesty je domovská složka uživatele služby. Pořadí: parametr DIR >
  proměnná prostředí (`CLAUDE_RC_DIR`, `CLAUDE_RC_HOST`, `CLAUDE_RC_UNIT`, `CLAUDE_RC_USER`)
  > config > výchozí hodnota. `sudo` proměnné prostředí obvykle nepředá, proto pro `install`
  raději config nebo parametr DIR. Změna `hostName`, `unitPrefix` nebo `serviceUser` platí až
  po `install`.
- Uživatel služby (`serviceUser`) nesmí být root. Výchozí je uživatel, který skript spustil
  (pod `sudo` `SUDO_USER`). `init` se spouští jako tento uživatel bez `sudo`, jinak by se
  důvěra složky uložila rootovi.
- Bez terminálu se `claude remote-control` nemůže zeptat na důvěru složky a skončí chybou
  `Workspace not trusted`; proto nejdřív `init`. Složka serveru nesmí být přímo domovská
  složka: pro tu Claude Code důvěru neuloží.
- Přihlášení: `claude auth login` účtem claude.ai. Token z `claude setup-token` ani API klíč
  Remote Control neumí; skript `CLAUDE_CODE_OAUTH_TOKEN` a `ANTHROPIC_API_KEY` pro server
  z prostředí odstraní.
- `install`, `start`, `stop`, `restart` a `uninstall` potřebují root (`sudo`), `status` ne.
  `stop` službu zastaví do dalšího startu systému nebo `start`; trvale ji zruší `uninstall`.
  `stop`, `uninstall` a `status` fungují i pro smazanou složku serveru.
- Když server po `install` nebo `start` neběží stabilně, skript ukáže posledních 5 řádků
  journalu a jednotku zastaví a zakáže (jinak by ji `Restart=always` spouštěl dokola).
- Server bez terminálu překresluje stavový řádek (v journalu zhruba 6 řádků za sekundu). Jednotka
  proto omezuje log na 25 řádků za 10 minut (`LogRateLimitIntervalSec`, `LogRateLimitBurst`);
  journald tuto hodnotu násobí podle volného místa pro journal (1× až 6×, viz `man journald.conf`),
  např. při 101 GB volných je strop 150 řádků. Start, URL a první chyby se vejdou, zbytek journald
  zahodí a zapíše `Suppressed N messages`.
- PATH služby = adresář `claude` + PATH login shellu uživatele služby + systémové cesty;
  po změně nástrojů (např. nvm) zopakovat `install`.

## Licence

MIT, viz `LICENSE`.
