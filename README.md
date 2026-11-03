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
Příkazy běží jako root, kroky 3 a 5 jako uživatel služby.

1. Git (sessions s ním pracují v repozitářích, tady i pro stažení skriptu) a uživatel služby
   se složkou serveru:

   ```bash
   dnf -y install git
   useradd -m -s /bin/bash claude
   su - claude -c 'mkdir -p ~/Repos'
   ```

2. Claude Code pro uživatele služby, nativní instalátor (`~/.local/bin/claude`, aktualizuje se sám):

   ```bash
   su - claude -c 'curl -fsSL https://claude.ai/install.sh | bash'
   su - claude -c 'claude --version'
   ```

3. Přihlášení účtem claude.ai. Bez prohlížeče: otevřít vypsanou URL na jiném počítači a kód
   vložit zpět do terminálu. Token z `claude setup-token` pro Remote Control nestačí.

   ```bash
   su - claude
   claude auth login
   exit
   ```

4. Skript a config. Kopie skriptu musí být čitelná pro uživatele služby; `serviceUser` je nutné
   nastavit, protože root bez `sudo` uživatele služby nezná:

   ```bash
   git clone https://github.com/dnemecek/linux-scripts.git ~/linux-scripts
   install -m 755 ~/linux-scripts/bin/claude-rc.sh /usr/local/bin/
   install -m 644 ~/linux-scripts/bin/claude-rc.conf.example /usr/local/bin/claude-rc.conf
   sed -i 's/^#serviceUser=$/serviceUser=claude/' /usr/local/bin/claude-rc.conf
   ```

5. První spuštění jako uživatel služby: odpovědět `y` na důvěru složky a na
   „Enable Remote Control?“, po výpisu běžícího serveru Ctrl+C:

   ```bash
   su - claude -c 'claude-rc.sh init'
   ```

6. Služba (systemd ji spouští od startu systému, bez přihlášení):

   ```bash
   claude-rc.sh install
   claude-rc.sh status
   ```

Session `<hostName> - Repos` je pak v seznamu na claude.ai/code a v aplikaci Claude.

### Provoz

```bash
claude-rc.sh status                  # stav, PID, počet restartů; chybějící složku označí MISSING
claude-rc.sh restart | stop | start  # root (nebo sudo)
claude-rc.sh uninstall               # zrušení služby, root (nebo sudo)
journalctl -u claude-rc-Repos        # log serveru (root nebo skupina systemd-journal)
```

Aktualizace skriptu: `git -C ~/linux-scripts pull`, znovu `install -m 755 …` z kroku 4
a `claude-rc.sh restart`.

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
