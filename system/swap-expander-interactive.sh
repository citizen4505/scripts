#!/usr/bin/env bash
#
# swap-expander-interactive.sh
# Interaktivni pridani dalsiho swapovaciho souboru.
#
# Pouziti:  ./swap-expander-interactive.sh
#

set -euo pipefail

DEFAULT_PATH="/swapfile2"
DEFAULT_SIZE="8G"

# ---------- pomocne funkce ----------

info()  { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[CHYBA]\033[0m %s\n' "$*" >&2; exit 1; }

# ask_yes_no "otazka" "a|n"  -> navratovy kod 0 = ano, 1 = ne
ask_yes_no() {
    local prompt="$1" default="${2:-n}" hint answer
    if [[ "$default" == "a" ]]; then hint="[A/n]"; else hint="[a/N]"; fi
    while true; do
        read -r -p "$prompt $hint " answer || exit 1
        answer="${answer:-$default}"
        case "${answer,,}" in
            a|ano|y|yes) return 0 ;;
            n|ne|no)     return 1 ;;
            *) echo "Odpovez prosim 'a' nebo 'n'." ;;
        esac
    done
}

# ---------- kontroly prostredi ----------

if [[ $EUID -ne 0 ]]; then
    info "Skript potrebuje prava roota, spoustim znovu pres sudo..."
    exec sudo -- bash "$0" "$@"
fi

for cmd in fallocate mkswap swapon swapoff df numfmt; do
    command -v "$cmd" >/dev/null 2>&1 || die "Chybi prikaz: $cmd"
done

# ---------- aktualni stav ----------

echo
info "Aktualni stav pameti a swapu:"
free -h
echo
swapon --show || true
echo

# ---------- cesta k souboru ----------

OVERWRITE=0
while true; do
    read -r -p "Cesta k novemu swap souboru [$DEFAULT_PATH]: " SWAP_PATH || exit 1
    SWAP_PATH="${SWAP_PATH:-$DEFAULT_PATH}"

    if [[ "$SWAP_PATH" != /* ]]; then
        warn "Zadej absolutni cestu (zacinajici /)."
        continue
    fi

    SWAP_DIR="$(dirname -- "$SWAP_PATH")"
    if [[ ! -d "$SWAP_DIR" ]]; then
        warn "Adresar $SWAP_DIR neexistuje."
        continue
    fi

    if [[ -d "$SWAP_PATH" ]]; then
        warn "$SWAP_PATH je adresar."
        continue
    fi

    if swapon --show=NAME --noheadings | grep -Fxq -- "$SWAP_PATH"; then
        warn "$SWAP_PATH je uz aktivni swap. Zvol jinou cestu."
        continue
    fi

    if [[ -e "$SWAP_PATH" ]]; then
        warn "Soubor $SWAP_PATH uz existuje ($(du -h -- "$SWAP_PATH" | cut -f1))."
        if ask_yes_no "Prepsat ho?" "n"; then
            OVERWRITE=1
        else
            continue
        fi
    fi
    break
done

# ---------- velikost ----------

AVAIL_BYTES="$(df --output=avail -B1 -- "$SWAP_DIR" | tail -n1 | tr -d ' ')"
FS_TYPE="$(df --output=fstype -- "$SWAP_DIR" | tail -n1 | tr -d ' ')"
info "Volne misto v $SWAP_DIR: $(numfmt --to=iec "$AVAIL_BYTES") (souborovy system: $FS_TYPE)"

while true; do
    read -r -p "Velikost swapu, napr. 512M, 4G, 8G [$DEFAULT_SIZE]: " SWAP_SIZE || exit 1
    SWAP_SIZE="${SWAP_SIZE:-$DEFAULT_SIZE}"
    SWAP_SIZE="${SWAP_SIZE^^}"

    if [[ ! "$SWAP_SIZE" =~ ^[1-9][0-9]*[MG]$ ]]; then
        warn "Neplatny format. Pouzij cislo a jednotku M nebo G (napr. 8G)."
        continue
    fi

    SIZE_BYTES="$(numfmt --from=iec "$SWAP_SIZE")"

    if (( SIZE_BYTES < 40 * 1024 * 1024 )); then
        warn "Swap musi mit aspon 40M."
        continue
    fi

    if (( SIZE_BYTES >= AVAIL_BYTES )); then
        warn "Na disku neni dost mista (pozadovano $SWAP_SIZE, volno $(numfmt --to=iec "$AVAIL_BYTES"))."
        continue
    fi

    # varovani, kdyz by zbylo mene nez 1 GiB
    if (( AVAIL_BYTES - SIZE_BYTES < 1024 * 1024 * 1024 )); then
        warn "Po vytvoreni zbyde na disku mene nez 1G volneho mista."
        ask_yes_no "Presto pokracovat s touto velikosti?" "n" || continue
    fi
    break
done

# ---------- trvalost ----------

PERSIST=0
if ask_yes_no "Zapsat swap do /etc/fstab, aby se aktivoval i po restartu?" "a"; then
    PERSIST=1
fi

# ---------- souhrn a potvrzeni ----------

echo
echo "================ SOUHRN ================"
echo "  Soubor:        $SWAP_PATH"
echo "  Velikost:      $SWAP_SIZE"
echo "  Souborovy sys: $FS_TYPE"
echo "  Prepsat:       $([[ $OVERWRITE -eq 1 ]] && echo ano || echo ne)"
echo "  Zapis do fstab: $([[ $PERSIST -eq 1 ]] && echo ano || echo ne)"
echo "========================================"
echo

ask_yes_no "Provest?" "n" || { info "Zruseno, nic se nezmenilo."; exit 0; }

# ---------- provedeni ----------

CREATED=0
ACTIVATED=0

cleanup() {
    local rc=$?
    if (( rc != 0 )) && (( CREATED == 1 )) && (( ACTIVATED == 0 )); then
        warn "Doslo k chybe, odstranuji nedokonceny soubor $SWAP_PATH"
        rm -f -- "$SWAP_PATH"
    fi
}
trap cleanup EXIT

if (( OVERWRITE == 1 )); then
    rm -f -- "$SWAP_PATH"
fi

info "Vytvarim soubor $SWAP_PATH ($SWAP_SIZE)..."
CREATED=1

if [[ "$FS_TYPE" == "btrfs" ]]; then
    # na btrfs musi byt swap soubor bez copy-on-write a bez komprese
    truncate -s 0 -- "$SWAP_PATH"
    chattr +C -- "$SWAP_PATH"
    fallocate -l "$SIZE_BYTES" -- "$SWAP_PATH"
elif ! fallocate -l "$SIZE_BYTES" -- "$SWAP_PATH" 2>/dev/null; then
    warn "fallocate selhal, pouzivam dd (potrva dele)..."
    rm -f -- "$SWAP_PATH"
    dd if=/dev/zero of="$SWAP_PATH" bs=1M count=$(( SIZE_BYTES / 1024 / 1024 )) status=progress
fi

chmod 600 -- "$SWAP_PATH"
ok "Soubor vytvoren, prava nastavena na 600."

info "Formatuji jako swap..."
mkswap -- "$SWAP_PATH" >/dev/null
ok "mkswap hotovo."

info "Aktivuji swap..."
if ! swapon -- "$SWAP_PATH" 2>/dev/null; then
    # nektere souborove systemy nesnesou soubor s "dirami" z fallocate
    warn "swapon selhal, zkousim soubor vytvorit znovu pomoci dd..."
    rm -f -- "$SWAP_PATH"
    dd if=/dev/zero of="$SWAP_PATH" bs=1M count=$(( SIZE_BYTES / 1024 / 1024 )) status=progress
    chmod 600 -- "$SWAP_PATH"
    mkswap -- "$SWAP_PATH" >/dev/null
    swapon -- "$SWAP_PATH"
fi
ACTIVATED=1
ok "Swap je aktivni."

if (( PERSIST == 1 )); then
    if awk -v p="$SWAP_PATH" '$1 == p && $1 !~ /^#/ { found = 1 } END { exit !found }' /etc/fstab; then
        info "Zaznam pro $SWAP_PATH uz v /etc/fstab je, nic nepridavam."
    else
        BACKUP="/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a /etc/fstab "$BACKUP"
        printf '%s none swap sw 0 0\n' "$SWAP_PATH" >> /etc/fstab
        ok "Zapsano do /etc/fstab (zaloha: $BACKUP)."
    fi
fi

# ---------- vysledek ----------

echo
info "Novy stav:"
free -h
echo
swapon --show
echo
ok "Hotovo."
echo "Pro odstraneni: sudo swapoff $SWAP_PATH && sudo rm $SWAP_PATH (a smazat radek z /etc/fstab)."
