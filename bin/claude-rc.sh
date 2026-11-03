#!/bin/bash
#
# Soubor: claude-rc.sh
# Projekt: linux-scripts
# Autor: David Nemecek
# Datum: 2026-11-02
# Popis: Claude Code Remote Control server jako sluzba systemd (systemova jednotka s User=).
#        Sessions jdou zakladat a ovladat z mobilu nebo z claude.ai/code.
#
# Verze: 1.0.0
#
# Pouziti:  claude-rc.sh init      [DIR]   prvni spusteni v popredi (jako uzivatel sluzby, ne root):
#                                          potvrdit duveru slozky a Remote Control
#           claude-rc.sh install   [DIR]   vytvori, povoli a spusti sluzbu (sudo)
#           claude-rc.sh start     [DIR]   povoli a spusti nainstalovanou sluzbu (sudo)
#           claude-rc.sh stop      [DIR]   zastavi sluzbu do dalsiho startu systemu nebo start (sudo)
#           claude-rc.sh restart   [DIR]   restartuje sluzbu (sudo)
#           claude-rc.sh status            nainstalovane sluzby, stav, PID a pocet restartu
#           claude-rc.sh uninstall [DIR]   zastavi a odstrani sluzbu (sudo)
#           claude-rc.sh run       DIR     jen pro systemd: overi slozku serveru a spusti server
#
# DIR = slozka serveru (nad ni server bezi, obsahuje workspaces). Bez DIR plati serverDir z configu.
# Config: claude-rc.conf vedle skriptu (jinak cesta v CLAUDE_RC_CONFIG), radky klic=hodnota,
# vzor claude-rc.conf.example. Poradi: parametr DIR > promenna prostredi > config > vychozi.
#   serverDir         CLAUDE_RC_DIR        vychozi <home uzivatele sluzby>/Repos
#   hostName          CLAUDE_RC_HOST       vychozi hostname -s
#   unitPrefix        CLAUDE_RC_UNIT       vychozi claude-rc
#   serviceUser       CLAUDE_RC_USER       vychozi uzivatel, ktery skript spustil (pod sudo SUDO_USER)
#
# Nazev v seznamu sessions je "<hostName> - <slozka>", nove sessions dostanou prefix
# "<hostName>". Jedna sluzba na nazev slozky: /etc/systemd/system/<unitPrefix>-<slozka>.service.
# Jednotka je systemova (bezi od startu systemu bez prihlaseni) a server bezi pod uzivatelem
# serviceUser (User=), protoze prihlaseni Claude Code a duvera slozek patri tomuto uzivateli.
# systemd spousti "claude-rc.sh run DIR", ktery pri kazdem startu overi slozku serveru a pak
# se nahradi procesem claude remote-control (PID drzi systemd). systemd server hlida
# (Restart=always): po startu systemu, po padu i po ukonceni serveru, ktery se ~10 min nemohl
# pripojit. Skript sam zadne procesy nehleda ani neukoncuje. Vystup jde do journalu.
# Bez terminalu se claude remote-control nemuze zeptat na duveru slozky a skonci chybou
# "Workspace not trusted" -- proto pred install jednou init.
#
# Predpoklady: Claude Code prihlaseny uctem claude.ai (Pro/Max/Team/Enterprise) pres
#              "claude auth login", ne API klicem ani tokenem z "claude setup-token";
#              systemd, util-linux (runuser), coreutils (timeout).
#

set -o pipefail

readonly SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly CONFIG_FILE="${CLAUDE_RC_CONFIG:-$(dirname "$SCRIPT_PATH")/claude-rc.conf}"
readonly UNIT_DIR="/etc/systemd/system"
# Max. delka nazvu jednotky systemd vcetne pripony .service
readonly UNIT_NAME_MAX=255

readonly RED='\033[1;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Hodnoty z configu (load_config); vychozi hodnoty doplni apply_settings
cfgServerDir=""
cfgHostName=""
cfgUnitPrefix=""
cfgServiceUser=""

# Cil: Vypise chybu cervene na stderr.
error()   { echo -e "${RED}[ERROR] $1${NC}" >&2; }
# Cil: Vypise varovani zlute na stdout.
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
# Cil: Vypise uspech zelene na stdout.
success() { echo -e "${GREEN}[OK] $1${NC}"; }
# Cil: Zapise radek do journalu sluzby (stdout procesu pod systemd; cas doplni journal).
log_line() { echo "[$1] $2"; }

# Cil: Vypise blok Pouziti z hlavicky (od "# Pouziti:" po prvni prazdny komentar) a skonci s kodem 1.
# Mantinely: Jen cte hlavicku $0. Konec bloku je prvni radek presne "#", proto do bloku Pouziti
#            nevkladat prazdny komentar.
# Kontrola: Vzdy exit 1; bez bloku Pouziti v hlavicce nevypise nic.
usage() {
    sed -n '/^# Pouziti:/,/^#$/{/^#$/d;s/^# //;p;}' "$0"
    exit 1
}

# Cil: Overi, ze jsou k dispozici zadane prikazy.
# Mantinely: Jen cte. claude se hleda zvlast (find_claude) v PATH uzivatele sluzby, protoze
#            sudo PATH nahrazuje (secure_path) a ~/.local/bin v nem neni.
# Kontrola: Chybejici prikaz ukonci skript exit 1 s nazvem prikazu.
require_cmds() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null || { error "Missing dependency: $cmd"; exit 1; }
    done
}

# Cil: Ukonci skript chybou, kdyz nebezi pod rootem (install, start, stop, restart, uninstall).
# Mantinely: Jen cte; jednotky v /etc/systemd/system a systemctl enable/start vyzaduji root.
# Kontrola: id -u je 0; jinak exit 1 s napovedou na sudo.
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "This command needs root. Run: sudo $0 $1"
        exit 1
    fi
}

# Cil: Nacte config (klic=hodnota) do promennych cfg*.
# Mantinely: Config je volitelny; chybejici soubor neni chyba. Soubor se NEspousti (source),
#            cte se po radcich: povolene klice serverDir, hostName, unitPrefix, serviceUser;
#            prazdne radky a komentare se preskoci. Komentar zacina # na zacatku radku nebo za
#            mezerou, takze # uvnitr hodnoty (napr. cesta /srv/a#b) zustane soucasti hodnoty.
#            Komentar se odrizne pred zpracovanim uvozovek: ani v uvozovkach nejde zapsat " #"
#            (z "/srv/my #x" zbyde "/srv/my a hlasi se nesparovana uvozovka).
#            Uvozovky kolem hodnoty se odstrani jen sparovane; osamela uvozovka je preklep a chyba,
#            jinak by se tise nacetla jina hodnota.
#            ~, ~/cesta, $HOME a $HOME/cesta (ne ~uzivatel, ne $HOMEX) rozvine az apply_settings, protoze pod sudo neni
#            $HOME domovem uzivatele sluzby. Neznamy klic nebo spatny radek = chyba.
# Kontrola: Navratovy kod 0 a nastavene cfg*; jinak exit 1 s cislem radku.
load_config() {
    local line key value lineNo=0 lineRe='^([A-Za-z]+)=(.*)$' dqRe='^"(.*)"$' sqRe="^'(.*)'$"
    [[ -f "$CONFIG_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineNo=$((lineNo + 1))
        line="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"${line%%[[:space:]]#*}")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ ! "$line" =~ $lineRe ]]; then
            error "Invalid line $lineNo in $CONFIG_FILE (expected key=value)"
            exit 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ $dqRe || "$value" =~ $sqRe ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" == [\"\']* || "$value" == *[\"\'] ]]; then
            error "Unmatched quote on line $lineNo in $CONFIG_FILE"; exit 1
        fi
        case "$key" in
            serverDir)   cfgServerDir="$value" ;;
            hostName)    cfgHostName="$value" ;;
            unitPrefix)  cfgUnitPrefix="$value" ;;
            serviceUser) cfgServiceUser="$value" ;;
            *) error "Unknown key '$key' on line $lineNo in $CONFIG_FILE"; exit 1 ;;
        esac
    done <"$CONFIG_FILE"
}

# Cil: Nastavi konstanty SERVICE_USER, USER_HOME, DEFAULT_DIR, HOST_NAME a UNIT_PREFIX
#      (prostredi > config > vychozi).
# Mantinely: SERVICE_USER existujici uzivatel, ne root (UID 0) -- server by bezel s pravy roota
#            a duvera slozek by patrila rootovi. USER_HOME z passwd (getent), ne z $HOME.
#            DEFAULT_DIR absolutni cesta (~, ~/..., $HOME a $HOME/... = USER_HOME); HOST_NAME 1-63 znaku
#            A-Z a-z 0-9 mezera . _ -; UNIT_PREFIX A-Z a-z 0-9 -, protoze je soucasti nazvu jednotky.
# Kontrola: Neplatna hodnota ukonci skript exit 1 se jmenem klice a zdrojem hodnoty.
apply_settings() {
    local serverDir hostName unitPrefix serviceUser userHome uid
    local hostRe='^[A-Za-z0-9._ -]{1,63}$' unitRe='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'
    local userRe='^[a-z_][a-z0-9_.-]{0,31}$'
    serviceUser="${CLAUDE_RC_USER:-${cfgServiceUser:-${SUDO_USER:-$(id -un)}}}"
    if [[ ! "$serviceUser" =~ $userRe ]]; then
        error "serviceUser is not a valid user name: '$serviceUser' (config $CONFIG_FILE or CLAUDE_RC_USER)"
        exit 1
    fi
    if ! uid="$(id -u "$serviceUser" 2>/dev/null)"; then
        error "serviceUser does not exist: '$serviceUser' (config or CLAUDE_RC_USER)"
        exit 1
    fi
    if [[ "$uid" -eq 0 ]]; then
        error "serviceUser must not be root. Set serviceUser in $CONFIG_FILE or run via sudo from that user."
        exit 1
    fi
    # Koncova lomitka pryc hned ("/home/u/" -> "/home/u"), jinak by ~/x dalo "/home/u//x".
    # Home "/" nebo "//" tak zustane prazdny a odmitne se.
    userHome="$(getent passwd "$serviceUser" | cut -d: -f6 | sed 's:/*$::')"
    if [[ "$userHome" != /?* ]]; then
        error "Home directory of serviceUser '$serviceUser' not found in passwd or is /."
        exit 1
    fi
    serverDir="${CLAUDE_RC_DIR:-${cfgServerDir:-$userHome/Repos}}"
    # Jen ~ a ~/... (ne ~jinyuzivatel); jinak by se jmeno spojilo s cestou home bez lomitka
    case "$serverDir" in
        "~"|"~/"*)         serverDir="$userHome${serverDir#\~}" ;;
        '$HOME'|'$HOME/'*) serverDir="$userHome${serverDir#\$HOME}" ;;
    esac
    hostName="${CLAUDE_RC_HOST:-${cfgHostName:-$(hostname -s)}}"
    unitPrefix="${CLAUDE_RC_UNIT:-${cfgUnitPrefix:-claude-rc}}"
    if [[ "$serverDir" != /* ]]; then
        error "serverDir must be an absolute path: '$serverDir' (config $CONFIG_FILE or CLAUDE_RC_DIR)"
        exit 1
    fi
    if [[ ! "$hostName" =~ $hostRe ]]; then
        error "hostName must be 1-63 chars A-Z a-z 0-9 space . _ -: '$hostName' (config or CLAUDE_RC_HOST)"
        exit 1
    fi
    if [[ ! "$unitPrefix" =~ $unitRe ]]; then
        error "unitPrefix must be A-Z a-z 0-9 - (no leading/trailing -): '$unitPrefix' (config or CLAUDE_RC_UNIT)"
        exit 1
    fi
    readonly SERVICE_USER="$serviceUser" USER_HOME="$userHome" DEFAULT_DIR="$serverDir"
    readonly HOST_NAME="$hostName" UNIT_PREFIX="$unitPrefix"
}

# Cil: Nastavi workDir (absolutni cesta), baseName (nazev slozky), unitName a unitPath.
# Mantinely: Vstup je cesta ke slozce nebo prazdny (pak DEFAULT_DIR). Neexistujici slozka
#            ukonci skript jen s parametrem must_exist (init, install, start, restart, run);
#            stop, uninstall a status musi jit i pro smazanou slozku. Slozka serveru nesmi byt
#            domovska slozka uzivatele sluzby: Claude Code pro ni duveru neulozi a sluzba by vzdy
#            skoncila "Workspace not trusted". Do unitName jdou jen znaky A-Z a-z 0-9 . _ -
#            (ostatni nahradi pomlcka); kolizi slozek se stejnym nazvem hlida check_owner.
# Kontrola: Navratovy kod 0 a nastavene promenne; jinak exit 1 s chybou.
resolve() {
    local dir="${1:-$DEFAULT_DIR}" mode="${2:-}" homeReal workReal
    if [[ -d "$dir" ]]; then
        # Fyzicka cesta (pwd -P): tataz slozka zadana pres symlink da stejny WorkingDirectory
        # a check_owner ji nevezme za cizi
        workDir="$(cd "$dir" && pwd -P)"
    elif [[ "$mode" == "must_exist" ]]; then
        error "Server directory not found: $dir"
        exit 1
    else
        # Smazana slozka: absolutni cesta bez cd (odstrani koncove lomitko)
        [[ "$dir" == /* ]] || dir="$PWD/$dir"
        workDir="${dir%/}"
    fi
    # Porovnani i po rozvinuti symlinku (home muze byt symlink)
    homeReal="$(cd "$USER_HOME" 2>/dev/null && pwd -P)"
    workReal="$(cd "$workDir" 2>/dev/null && pwd -P)"
    if [[ "$workDir" == "$USER_HOME" || ( -n "$workReal" && "$workReal" == "$homeReal" ) ]]; then
        error "Server directory must not be the home directory of $SERVICE_USER: $workDir"
        echo "  Claude Code does not keep trust for the home directory. Use a subfolder (e.g. $USER_HOME/Repos)." >&2
        exit 1
    fi
    baseName="$(basename "$workDir")"
    unitName="${UNIT_PREFIX}-$(sed 's/[^A-Za-z0-9._-]/-/g' <<<"$baseName").service"
    if [[ ${#unitName} -gt $UNIT_NAME_MAX ]]; then
        error "Unit name too long (max $UNIT_NAME_MAX chars): $unitName"
        exit 1
    fi
    unitPath="${UNIT_DIR}/${unitName}"
}

# Cil: Vypise hodnotu vlastnosti jednotky unitName (systemctl show, napr. MainPID, ActiveState).
unit_prop() {
    systemctl show -p "$1" --value "$unitName" 2>/dev/null
}

# Cil: Vrati 0, kdyz jednotka bezi nebo ceka na restart (ActiveState active/activating/...), jinak 1.
# Pozn.: Po padu ceka jednotka RestartSec ve stavu activating (auto-restart) -- i ta se pocita jako
# bezici, jinak by ji stop nezastavil a systemd by server za 30 s spustil znovu.
is_active() {
    case "$(unit_prop ActiveState)" in
        active|activating|reloading|deactivating) return 0 ;;
        *) return 1 ;;
    esac
}

# Cil: Vypise MainPID jednotky; prazdny text, kdyz proces nebezi (systemd hlasi 0).
main_pid() {
    local pid
    pid="$(unit_prop MainPID)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && echo "$pid"
}

# Cil: Vypise hodnotu klice z jednotky (radek Klic=hodnota v unitPath, napr. WorkingDirectory).
unit_value() {
    sed -n "s/^$1=//p" "$unitPath" 2>/dev/null | head -1
}

# Cil: Ukonci skript chybou, kdyz sluzba pro workDir neni nainstalovana.
require_installed() {
    if [[ ! -f "$unitPath" ]]; then
        error "Service for $workDir is not installed. Run: sudo $0 install \"$workDir\""
        exit 1
    fi
}

# Cil: Overi, ze existujici jednotka unitName patri slozce workDir (stejny nazev maji slozky
#      se stejnym nazvem).
# Mantinely: Jen cte; bez souboru jednotky nic nekontroluje.
# Kontrola: Kdyz jednotka patri jine slozce, exit 1 s chybou a cestou te slozky.
check_owner() {
    local owner
    [[ -f "$unitPath" ]] || return 0
    owner="$(unit_value WorkingDirectory)"
    # Jednotka muze nest logickou cestu (symlink, starsi instalace); shoda plati i po rozvinuti
    # na fyzickou cestu, kterou ma workDir (resolve, pwd -P). Prazdny owner (jednotka bez
    # WorkingDirectory=) je vzdy cizi: cd "" je v bash no-op a pwd -P by vratil aktualni adresar.
    if [[ -z "$owner" || ( "$owner" != "$workDir" && "$(cd "$owner" 2>/dev/null && pwd -P)" != "$workDir" ) ]]; then
        error "Service $unitName belongs to another server directory: ${owner:-<no WorkingDirectory>}"
        echo "  One service per folder name. Remove it first: sudo $0 uninstall \"$owner\"" >&2
        exit 1
    fi
}

# Cil: Spusti prikaz jako uzivatel sluzby, bez CLAUDE_CODE_OAUTH_TOKEN a ANTHROPIC_API_KEY.
# Mantinely: Pod rootem pres runuser s HOME uzivatele sluzby; jinak primo (init bezi jako
#            uzivatel sluzby). Token z "claude setup-token" ani API klic Remote Control neumi
#            a mely by prednost pred plnym prihlasenim, proto se z prostredi odstrani.
# Kontrola: Navratovy kod a vystup spusteneho prikazu.
as_user() {
    if [[ "$(id -u)" -eq 0 ]]; then
        runuser -u "$SERVICE_USER" -- env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY HOME="$USER_HOME" "$@"
    else
        env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY "$@"
    fi
}

# Cil: Nastavi claudeBin (cesta ke claude) a userPath (PATH prihlasovaciho shellu uzivatele sluzby).
# Mantinely: Jen cte. PATH se bere z login shellu uzivatele sluzby (bash -l nacte jeho profil),
#            protoze sudo PATH nahrazuje a sessions potrebuji nastroje uzivatele (git, gh, node...).
# Kontrola: claudeBin je absolutni cesta ke spustitelnemu souboru; jinak exit 1 s napovedou.
find_claude() {
    claudeBin="$(as_user bash -lc 'command -v claude' 2>/dev/null </dev/null | tail -1)"
    userPath="$(as_user bash -lc 'printf "%s" "$PATH"' 2>/dev/null </dev/null | tail -1)"
    if [[ "$claudeBin" != /* || ! -x "$claudeBin" ]]; then
        error "claude not found in PATH of user $SERVICE_USER."
        echo "  Install Claude Code as $SERVICE_USER and check: su - $SERVICE_USER -c 'command -v claude'" >&2
        exit 1
    fi
}

# Cil: Overi, ze Claude Code uzivatele sluzby je prihlaseny uctem claude.ai (Remote Control
#      je k dispozici).
# Mantinely: Jen cte; bez prihlaseni skonci exit 1 s navodem. Bez platneho prihlaseni claude.ai
#            vypise --help chybu misto napovedy. --help po vypisu sam neskonci, proto casovy limit
#            pres timeout a rozhoduje text vystupu, ne navratovy kod. Vyzaduje claudeBin (find_claude).
# Kontrola: Vystup claude remote-control --help obsahuje USAGE.
check_login() {
    local helpText
    helpText=$(as_user timeout 10 "$claudeBin" remote-control --help </dev/null 2>&1)
    if ! grep -q "USAGE" <<<"$helpText"; then
        error "Remote Control not available: Claude Code of $SERVICE_USER is not logged in with a claude.ai account."
        echo "  As $SERVICE_USER run 'claude auth login' and choose a Claude subscription account" >&2
        echo "  (not Anthropic Console). Tokens from 'claude setup-token' do not work for Remote Control." >&2
        exit 1
    fi
}

# Cil: Overi, ze hodnota jde bezpecne zapsat do jednotky systemd.
# Mantinely: Odmitne znaky, ktere systemd v jednotce interpretuje (" \ % $), ridici znaky
#            vcetne konce radku a mezeru na konci (systemd ji orizne). Jinak by se cesta v jednotce
#            zmenila nebo rozpadla.
# Kontrola: Neplatna hodnota ukonci skript exit 1 se jmenem hodnoty.
check_unit_safe() {
    local name="$1" value="$2" badRe='["\\%$]|[[:cntrl:]]|[[:space:]]$'
    if [[ "$value" =~ $badRe ]]; then
        error "$name contains a character not supported in a systemd unit (\" \\ % \$, control, trailing space): $value"
        exit 1
    fi
}

# Cil: Overi, ze uzivatel sluzby muze cist skript a vstoupit do slozky serveru.
# Mantinely: Jen cte. systemd spousti skript a server pod User=; skript v /root nebo ve slozce
#            jineho uzivatele by sluzba nespustila.
# Kontrola: test -r skriptu a test -r -x slozky jako uzivatel sluzby; jinak exit 1.
check_user_access() {
    if ! as_user test -r "$SCRIPT_PATH"; then
        error "User $SERVICE_USER cannot read $SCRIPT_PATH. Deploy the script to a readable path (e.g. /usr/local/bin)."
        exit 1
    fi
    if ! as_user test -r "$workDir" -a -x "$workDir"; then
        error "User $SERVICE_USER cannot access server directory $workDir."
        exit 1
    fi
}

# Cil: Overi, ze sluzba po spusteni bezi stabilne (server neskoncil hned po startu).
# Mantinely: Ceka max. 10 s na MainPID odlisny od oldPid (restart) a pak 5 s overuje, ze se
#            nezmenil. Server, ktery spadne pozdeji, odhali az status. Pri neuspechu ukaze vystup
#            od casu since z journalu a jednotku zastavi a zakaze (disable), aby ji Restart=always
#            nespoustel dokola.
# Kontrola: Navratovy kod 0 a vypis uspechu; jinak 1 s chybou a radky journalu.
check_running() {
    local oldPid="${1:-}" since="$2" pid="" pid2 i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pid=$(main_pid)
        [[ -n "$pid" && "$pid" != "$oldPid" ]] && break
        pid=""
        sleep 1
    done
    sleep 5
    pid2=$(main_pid)
    if [[ -n "$pid" && "$pid" == "$pid2" ]]; then
        success "Service $unitName running (PID $pid, user $SERVICE_USER), server directory $workDir"
        return 0
    fi
    error "Service $unitName is not running stably (state $(unit_prop ActiveState)/$(unit_prop SubState),\
 exit status $(unit_prop ExecMainStatus))."
    echo "  Output of this start (journalctl -u $unitName):" >&2
    journalctl -u "$unitName" --since "$since" -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/    /' >&2
    systemctl disable --now "$unitName" >/dev/null 2>&1
    echo "  Service stopped and disabled. Workspace not trusted or Remote Control not enabled?" >&2
    echo "  As $SERVICE_USER run: $0 init \"$workDir\"" >&2
    return 1
}

# Cil: Spusti claude remote-control v popredi v terminalu, aby slo odpovedet na dotazy
#      na duveru slozky a zapnuti Remote Control.
# Mantinely: Bezi jako uzivatel sluzby, ne root (duvera by se ulozila rootovi). Slozka serveru musi
#            existovat. Kdyz sluzba pro workDir bezi, skonci chybou (dva servery ve stejne slozce).
#            Proces nahradi skript (exec), ukonceni Ctrl+C.
# Kontrola: Server vypise, ze bezi; pak Ctrl+C a install nebo start.
cmd_init() {
    require_cmds claude
    if [[ "$(id -u)" -eq 0 ]]; then
        error "Do not run init as root (trust would be stored for root). Run it as $SERVICE_USER without sudo."
        exit 1
    fi
    if [[ "$(id -un)" != "$SERVICE_USER" ]]; then
        error "init must run as the service user $SERVICE_USER (current user: $(id -un))."
        exit 1
    fi
    resolve "$1" must_exist
    if is_active; then
        error "Service $unitName is running for $workDir. Stop it first: sudo $0 stop \"$workDir\""
        exit 1
    fi
    claudeBin="$(command -v claude)"
    check_login
    echo "Answer the trust and Remote Control questions. When the server is running, stop it"
    echo "with Ctrl+C and run: sudo $0 install \"$workDir\" (or start, if already installed)."
    cd "$workDir" || exit 1
    unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY
    exec claude remote-control --name "${HOST_NAME} - ${baseName}" --remote-control-session-name-prefix "$HOST_NAME"
}

# Cil: Spusteni serveru systemd: overi slozku serveru a claude, pak se nahradi procesem claude remote-control.
# Mantinely: Vola jen systemd z jednotky jako User= (HOST_NAME a UNIT_PREFIX z Environment=
#            jednotky). Chybejici slozku serveru nebo claude zapise do journalu a skonci exit 1;
#            systemd to zkusi znovu po RestartSec (30 s). Nic nemeni.
# Kontrola: Radek [ERROR] v journalu sluzby a status s MISSING u chybejici slozky serveru.
cmd_run() {
    if [[ -z "$1" ]]; then
        log_line ERROR "Missing server directory argument (run is called only by systemd from the unit)."
        exit 1
    fi
    if [[ ! -d "$1" ]]; then
        log_line ERROR "Server directory not found: $1. Restore it or run: sudo $0 uninstall \"$1\""
        exit 1
    fi
    if ! command -v claude >/dev/null; then
        log_line ERROR "claude not found in PATH ($PATH). Reinstall the service: sudo $0 install \"$1\""
        exit 1
    fi
    resolve "$1" must_exist
    log_line INFO "Starting claude remote-control '${HOST_NAME} - ${baseName}' in $workDir as $(id -un)"
    cd "$workDir" || exit 1
    # Dlouhodoby token (claude setup-token) ani API klic Remote Control neumi a mely by prednost
    # pred plnym prihlasenim uzivatele
    unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY
    exec claude remote-control --name "${HOST_NAME} - ${baseName}" --remote-control-session-name-prefix "$HOST_NAME"
}

# Cil: Vytvori systemovou jednotku systemd pro slozku serveru workDir, povoli ji a spusti.
# Mantinely: Root. Slozka serveru musi existovat. Prepise jen vlastni jednotku unitName; bezici
#            sluzbu restartuje s novou jednotkou (reinstall). Jednotku jine slozky se stejnym
#            nazvem neprepise (check_owner). systemd spousti "claude-rc.sh run DIR" z teto cesty
#            skriptu, bez TTY (vstup /dev/null), proto instalovat z nasazene kopie (napr.
#            /usr/local/bin), ne z pracovniho klonu. PATH sluzby = adresar claude + PATH login
#            shellu uzivatele sluzby (sessions potrebuji git, gh, node...) + systemove cesty;
#            po zmene nastroju (napr. nvm) je potreba install zopakovat.
# Kontrola: systemctl daemon-reload, enable, restart a check_running; jinak exit 1.
cmd_install() {
    require_root install
    resolve "$1" must_exist
    check_owner
    find_claude
    check_login
    check_user_access
    local pathEnv oldPid since
    pathEnv="$(dirname "$claudeBin"):${userPath}:/usr/local/bin:/usr/bin:/bin"
    check_unit_safe "Server directory" "$workDir"
    check_unit_safe "Script path" "$SCRIPT_PATH"
    check_unit_safe "PATH" "$pathEnv"
    oldPid=$(main_pid)
    (umask 022 && cat >"$unitPath") <<UNIT_END
[Unit]
Description=Claude Code Remote Control server ${HOST_NAME} - ${baseName}
After=network-online.target
Wants=network-online.target
# Server skonci po ~10 min bez site; vychozi limit startu by sluzbu po 5 pokusech vzdal
StartLimitIntervalSec=0

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${workDir}
Environment="PATH=${pathEnv}"
Environment="CLAUDE_RC_HOST=${HOST_NAME}"
Environment="CLAUDE_RC_UNIT=${UNIT_PREFIX}"
ExecStart=/bin/bash "${SCRIPT_PATH}" run "${workDir}"
Restart=always
RestartSec=30
# Server bez terminalu prekresluje stavovy radek (~6 radku/s v journalu) a vytlacil by ostatni logy; journald burst
# nasobi podle volneho mista (1-6x, journald.conf), start, URL a prvni chyby se vejdou, zbytek zahodi s poctem
LogRateLimitIntervalSec=10min
LogRateLimitBurst=25

[Install]
WantedBy=multi-user.target
UNIT_END
    [[ -s "$unitPath" ]] || { error "Failed to write $unitPath"; exit 1; }
    systemctl daemon-reload || { error "systemctl daemon-reload failed"; exit 1; }
    systemctl enable "$unitName" >/dev/null 2>&1 || { error "systemctl enable failed for $unitName"; exit 1; }
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    # restart = start nezastavene jednotky i nacteni nove jednotky u bezici (reinstall)
    systemctl restart "$unitName" || { error "systemctl restart failed for $unitName"; exit 1; }
    check_running "$oldPid" "$since" || exit 1
    echo "  Session name: '${HOST_NAME} - ${baseName}'"
    echo "  Unit: $unitPath"
    echo "  Log:  journalctl -u $unitName"
}

# Cil: Povoli a spusti nainstalovanou sluzbu pro slozku serveru workDir.
# Mantinely: Root. Slozka serveru musi existovat. Bez jednotky nebo s jednotkou jine slozky skonci
#            chybou; bezici sluzbu nemeni. Povoli i jednotku zakazanou po neuspesnem startu.
# Kontrola: check_running; jinak exit 1.
cmd_start() {
    require_root start
    resolve "$1" must_exist
    require_installed
    check_owner
    if is_active && [[ -n "$(main_pid)" ]]; then
        warn "Service $unitName is already running (PID $(main_pid))."
        exit 0
    fi
    find_claude
    check_login
    local since
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    # Jednotka ceka na restart (RestartSec) nebo stoji -- restart ji spusti hned
    systemctl enable "$unitName" >/dev/null 2>&1 || { error "systemctl enable failed for $unitName"; exit 1; }
    systemctl restart "$unitName" || { error "systemctl restart failed for $unitName"; exit 1; }
    check_running "" "$since" || exit 1
}

# Cil: Zastavi sluzbu pro slozku serveru workDir (do dalsiho startu systemu nebo start).
# Mantinely: Root. Jednotku ponecha povolenou. Proces ukonci systemd vcetne jeho podprocesu
#            (cgroup). Funguje i pro smazanou slozku serveru.
# Kontrola: Jednotka neni aktivni; jinak exit 1.
cmd_stop() {
    require_root stop
    resolve "$1"
    require_installed
    check_owner
    if ! is_active; then
        warn "Service $unitName is not running."
        exit 0
    fi
    systemctl stop "$unitName" || { error "systemctl stop failed for $unitName"; exit 1; }
    is_active && { error "Service $unitName is still active."; exit 1; }
    success "Service $unitName stopped (starts again at next boot or with: sudo $0 start \"$workDir\")."
}

# Cil: Restartuje bezici sluzbu pro slozku serveru workDir (systemctl restart).
# Mantinely: Root. Slozka serveru musi existovat. Neaktivni sluzbu jen spusti (jako start).
# Kontrola: check_running s PID puvodniho procesu (novy PID se musi lisit); jinak exit 1.
cmd_restart() {
    require_root restart
    resolve "$1" must_exist
    require_installed
    check_owner
    if ! is_active; then
        cmd_start "$1"
        return
    fi
    local oldPid since
    oldPid=$(main_pid)
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    systemctl restart "$unitName" || { error "systemctl restart failed for $unitName"; exit 1; }
    check_running "$oldPid" "$since" || exit 1
}

# Cil: Zastavi, zakaze a odstrani sluzbu pro slozku serveru workDir.
# Mantinely: Root. Smaze jen vlastni jednotku unitName (ne jednotku jine slozky se stejnym
#            nazvem); journal ponecha. Funguje i pro smazanou slozku serveru a bez Claude Code.
# Kontrola: Jednotka neni aktivni a soubor jednotky neexistuje; jinak exit 1.
cmd_uninstall() {
    require_root uninstall
    resolve "$1"
    if [[ ! -f "$unitPath" ]] && ! is_active; then
        warn "Service $unitName is not installed."
        exit 0
    fi
    check_owner
    if [[ -f "$unitPath" ]]; then
        systemctl disable --now "$unitName" >/dev/null 2>&1
    fi
    is_active && systemctl stop "$unitName"
    rm -f "$unitPath"
    systemctl daemon-reload
    systemctl reset-failed "$unitName" >/dev/null 2>&1
    if is_active || [[ -f "$unitPath" ]]; then
        error "Failed to remove service $unitName completely."
        exit 1
    fi
    success "Service $unitName removed (journal kept: journalctl -u $unitName)."
}

# Cil: Vypise nainstalovane sluzby: jednotku, slozku serveru, stav, PID, restarty a exit status.
# Mantinely: Jen cte; meni jen globalni unitPath a unitName, ze kterych ctou unit_prop a unit_value.
#            Jednotku bez Environment="CLAUDE_RC_UNIT=<unitPrefix>" (jiny prefix nebo rucne upravena)
#            preskoci.
# Kontrola: Vypis kazde vlastni jednotky, nebo hlaska, ze zadna neni nainstalovana.
cmd_status() {
    local found=0 dir pid
    for unitPath in "${UNIT_DIR}/${UNIT_PREFIX}"-*.service; do
        [[ -f "$unitPath" ]] || continue
        # Glob prefixu "claude" zachyti i jednotky prefixu "claude-rc"; vlastni jednotku pozna
        # Environment= s timto prefixem, ktery zapisuje cmd_install
        grep -qFx "Environment=\"CLAUDE_RC_UNIT=${UNIT_PREFIX}\"" "$unitPath" || continue
        found=1
        unitName="$(basename "$unitPath")"
        dir="$(unit_value WorkingDirectory)"
        echo "$unitName"
        if [[ -d "$dir" ]]; then
            echo "  directory: $dir"
        else
            echo "  directory: $dir (MISSING -- server cannot start; remove: sudo $0 uninstall \"$dir\")"
        fi
        pid="$(main_pid)"
        echo "  user:      $(unit_value User)"
        echo "  state:     $(unit_prop ActiveState)/$(unit_prop SubState) ($(unit_prop UnitFileState)),\
 PID ${pid:-none}"
        echo "  restarts:  $(unit_prop NRestarts), last exit status: $(unit_prop ExecMainStatus)"
    done
    [[ $found -eq 1 ]] || echo "No claude-rc service is installed (unit prefix $UNIT_PREFIX in $UNIT_DIR)."
}

require_cmds systemctl journalctl runuser timeout hostname getent
load_config
apply_settings

case "${1:-}" in
    init)      cmd_init      "${2:-}" ;;
    install)   cmd_install   "${2:-}" ;;
    start)     cmd_start     "${2:-}" ;;
    stop)      cmd_stop      "${2:-}" ;;
    restart)   cmd_restart   "${2:-}" ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall "${2:-}" ;;
    run)       cmd_run       "${2:-}" ;;
    *)         usage ;;
esac
