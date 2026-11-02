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

```bash
sudo install -m 755 bin/claude-rc.sh /usr/local/bin/        # nasazená kopie, čitelná pro uživatele služby
sudo cp bin/claude-rc.conf.example /usr/local/bin/claude-rc.conf   # config vedle skriptu, upravit hostName
claude auth login             # jako uživatel služby: přihlášení účtem claude.ai (předplatné)
claude-rc.sh init             # 1. jako uživatel služby (bez sudo): potvrdit důvěru a Remote Control, pak Ctrl+C
sudo claude-rc.sh install     # 2. služba pod uživatelem, který sudo spustil
claude-rc.sh status           # stav, PID, počet restartů; chybějící složku označí MISSING
sudo claude-rc.sh restart | stop | start
sudo claude-rc.sh uninstall   # zrušení služby
journalctl -u claude-rc-<složka>    # log serveru (sudo nebo skupina systemd-journal)
```

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
- PATH služby = adresář `claude` + PATH login shellu uživatele služby + systémové cesty;
  po změně nástrojů (např. nvm) zopakovat `install`.

## Licence

MIT, viz `LICENSE`.
