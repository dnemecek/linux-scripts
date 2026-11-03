# TODO

| # | Úkol | Stav |
|---|---|---|
| 1 | `bin/claude-rc.sh`: Claude Code Remote Control server jako služba systemd (rozhraní init, install, start, stop, restart, status, uninstall) | hotovo (Rocky 9.8, systemd 252) |
| 2 | Test na Rocky Linux v LXC kontejneru: přihlášení Claude Code předplatným bez GUI, služba přežije restart kontejneru | hotovo (restart, session z aplikace, limit logu) |
| 3 | Audit a publikace na GitHubu (LICENSE, README, kontrola celé historie před prvním pushem) | čeká |
| 4 | Otevřená otázka: journal bez `/var/log/journal` je jen v paměti (`/run`, výchozí strop 10 % velikosti, nejvýš 4 GB) – ověřit, zda se počítá do paměti LXC kontejneru, a případně nastavit `RuntimeMaxUse` nebo trvalý journal | čeká na rozhodnutí |
