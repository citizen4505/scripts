#!/usr/bin/env bash
#
# kontrola-androidu.sh
# Sběr dat z Androidu přes ADB a offline vyhodnocení na Linuxu.
#
# Použití:
#   ./kontrola-androidu.sh            # APK stáhne jen u aplikací mimo obchod
#   ./kontrola-androidu.sh --all-apk  # APK stáhne u všech aplikací třetích stran
#
# Potřebuje: adb. Volitelně: mvt-android (pipx install mvt), androidqf.
# Na telefonu: zapnuté Ladění USB a potvrzený dialog "Povolit ladění".
# Skript z telefonu pouze čte, nic na něm nemění ani nemaže.

set -uo pipefail

ALL_APK=0
[[ "${1:-}" == "--all-apk" ]] && ALL_APK=1

# Instalátory považované za důvěryhodné (obchody). Upravte podle svého telefonu.
DUVERYHODNE='^(com\.android\.vending|com\.sec\.android\.app\.samsungapps|com\.xiaomi\.mipicks|com\.huawei\.appmarket|org\.fdroid\.fdroid)$'

# Oprávnění typická pro odposlech a sledování.
CITLIVA='RECORD_AUDIO|CAMERA|ACCESS_FINE_LOCATION|ACCESS_BACKGROUND_LOCATION|READ_SMS|RECEIVE_SMS|READ_CALL_LOG|READ_CONTACTS|PROCESS_OUTGOING_CALLS|READ_PHONE_STATE'

OUT="kontrola-$(date +%Y%m%d-%H%M%S)"
SOUHRN="$OUT/SOUHRN.txt"

info()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
zapis() { printf '%s\n' "$*" | tee -a "$SOUHRN"; }
ash()   { adb shell "$@" </dev/null 2>/dev/null | tr -d '\r'; }

# ---------------------------------------------------------------- kontroly
command -v adb >/dev/null || { echo "Chybí adb (sudo apt install adb)."; exit 1; }

STAV="$(adb get-state 2>&1)"
if [[ "$STAV" != "device" ]]; then
  echo "Telefon není připraven (stav: $STAV)."
  echo "Zapněte Ladění USB, připojte kabel a potvrďte dialog na telefonu."
  exit 1
fi

mkdir -p "$OUT"/{raw,apk}
: > "$SOUHRN"

zapis "Kontrola Androidu - $(date)"
zapis "Zařízení: $(ash getprop ro.product.manufacturer) $(ash getprop ro.product.model)"
zapis "Android:  $(ash getprop ro.build.version.release), záplaty $(ash getprop ro.build.version.security_patch)"

# ---------------------------------------------------------------- 1. aplikace
info "1/7 Seznam aplikací"
ash pm list packages -3 -i > "$OUT/raw/aplikace-treti-strany.txt"
ash pm list packages -s    > "$OUT/raw/aplikace-systemove.txt"
ash pm list packages -d    > "$OUT/raw/aplikace-zakazane.txt"

# Převod na "balicek instalator"
sed -E 's/^package:([^ ]+) +installer=(.*)$/\1 \2/' \
  "$OUT/raw/aplikace-treti-strany.txt" > "$OUT/raw/balicky.txt"

mapfile -t VSECHNY < <(awk '{print $1}' "$OUT/raw/balicky.txt")
mapfile -t MIMO_OBCHOD < <(awk -v re="$DUVERYHODNE" '$2 !~ re {print $1}' "$OUT/raw/balicky.txt")

zapis ""
zapis "Aplikací třetích stran: ${#VSECHNY[@]}"
zapis "Z toho nainstalováno mimo obchod (ke kontrole): ${#MIMO_OBCHOD[@]}"
for p in "${MIMO_OBCHOD[@]}"; do
  inst="$(awk -v p="$p" '$1==p {print $2}' "$OUT/raw/balicky.txt")"
  zapis "  - $p   (instalátor: $inst)"
done

# ---------------------------------------------------------------- 2. zvláštní přístupy
info "2/7 Přístupnost, oznámení, správci zařízení"

A11Y="$(ash settings get secure enabled_accessibility_services)"
NOTIF="$(ash settings get secure enabled_notification_listeners)"
ash dumpsys device_policy > "$OUT/raw/device_policy.txt"
ash dumpsys accessibility > "$OUT/raw/accessibility.txt"

zapis ""
zapis "Služby přístupnosti (nejčastější cesta stalkerwaru):"
if [[ -z "$A11Y" || "$A11Y" == "null" ]]; then zapis "  žádné"
else tr ':' '\n' <<<"$A11Y" | sed 's/^/  - /' | tee -a "$SOUHRN"; fi

zapis ""
zapis "Aplikace čtoucí oznámení:"
if [[ -z "$NOTIF" || "$NOTIF" == "null" ]]; then zapis "  žádné"
else tr ':' '\n' <<<"$NOTIF" | sed 's/^/  - /' | tee -a "$SOUHRN"; fi

zapis ""
zapis "Správci zařízení (úplný výpis v raw/device_policy.txt):"
grep -A12 -i 'Enabled Device Admins' "$OUT/raw/device_policy.txt" \
  | grep -E '^\s+[a-zA-Z0-9_.]+/' | sed -E 's/^\s+/  - /; s/:$//' | tee -a "$SOUHRN"

# ---------------------------------------------------------------- 3. nastavení
info "3/7 Bezpečnostní nastavení"

PP="$(ash settings get global package_verifier_user_consent)"
zapis ""
case "$PP" in
  1)  zapis "Play Protect: zapnutý" ;;
  -1) zapis "Play Protect: VYPNUTÝ  <-- podezřelé, pokud jste ho nevypnuli sami" ;;
  *)  zapis "Play Protect: nezjištěno (hodnota: $PP), ověřte ručně v Obchodu Play" ;;
esac

zapis ""
zapis "Aplikace s povolenou instalací z neznámých zdrojů:"
ash appops query-op REQUEST_INSTALL_PACKAGES allow | sed 's/^/  - /' | tee -a "$SOUHRN"

zapis ""
zapis "Aplikace s povoleným zobrazením přes jiné aplikace:"
ash appops query-op SYSTEM_ALERT_WINDOW allow | sed 's/^/  - /' | tee -a "$SOUHRN"

ash settings list secure > "$OUT/raw/settings-secure.txt"
ash settings list global > "$OUT/raw/settings-global.txt"

# ---------------------------------------------------------------- 4. oprávnění
info "4/7 Citlivá oprávnění u aplikací mimo obchod"
zapis ""
zapis "Udělená citlivá oprávnění (aplikace mimo obchod):"
for p in "${MIMO_OBCHOD[@]}"; do
  ash dumpsys package "$p" > "$OUT/raw/pkg-$p.txt"
  PERM="$(grep -E "android\.permission\.($CITLIVA): granted=true" "$OUT/raw/pkg-$p.txt" \
          | sed -E 's/.*permission\.([A-Z_]+):.*/\1/' | sort -u | paste -sd, -)"
  [[ -n "$PERM" ]] && zapis "  - $p: $PERM"
done

ash dumpsys appops > "$OUT/raw/appops.txt"
ash ps -A          > "$OUT/raw/procesy.txt"
ash dumpsys batterystats --charged > "$OUT/raw/baterie.txt"
ash dumpsys netstats > "$OUT/raw/netstats.txt"

# ---------------------------------------------------------------- 5. APK a hashe
info "5/7 Stahování APK a výpočet hashů"
if (( ALL_APK )); then CILE=("${VSECHNY[@]}"); else CILE=("${MIMO_OBCHOD[@]}"); fi

: > "$OUT/hashe.txt"
for p in "${CILE[@]}"; do
  mkdir -p "$OUT/apk/$p"
  while read -r cesta; do
    [[ -z "$cesta" ]] && continue
    adb pull "$cesta" "$OUT/apk/$p/" </dev/null >/dev/null 2>&1
  done < <(ash pm path "$p" | sed 's/^package://')
  for f in "$OUT/apk/$p"/*.apk; do
    [[ -f "$f" ]] || continue
    h="$(sha256sum "$f" | awk '{print $1}')"
    printf '%s  %s  %s\n' "$h" "$p" "$(basename "$f")" >> "$OUT/hashe.txt"
  done
done

zapis ""
zapis "Odkazy na VirusTotal (vyhledání podle hashe, soubor se nikam nenahrává):"
awk '$3=="base.apk" {printf "  - %s\n    https://www.virustotal.com/gui/file/%s\n", $2, $1}' \
  "$OUT/hashe.txt" | tee -a "$SOUHRN"

# ---------------------------------------------------------------- 6. bugreport
info "6/7 Bugreport (trvá několik minut)"
adb bugreport "$OUT/bugreport.zip" </dev/null >/dev/null 2>&1 \
  && echo "Uloženo: $OUT/bugreport.zip" \
  || echo "Bugreport se nepodařilo vytvořit."

# ---------------------------------------------------------------- 7. MVT
info "7/7 Vyhodnocení pomocí MVT"
zapis ""
if command -v mvt-android >/dev/null; then
  mvt-android download-iocs >/dev/null 2>&1

  if [[ -f "$OUT/bugreport.zip" ]]; then
    mvt-android check-bugreport -o "$OUT/mvt-bugreport" "$OUT/bugreport.zip" \
      > "$OUT/raw/mvt-bugreport.log" 2>&1
  fi

  # AndroidQF je interaktivní, spustí se jen pokud je k dispozici.
  QF="$(command -v androidqf || true)"
  [[ -z "$QF" && -x ./androidqf ]] && QF="$(realpath ./androidqf)"
  if [[ -n "$QF" ]]; then
    ZNACKA="$(mktemp)"
    echo "Spouštím AndroidQF, odpovězte na jeho dotazy."
    "$QF"
    # Výstupní složku hledáme v aktuálním adresáři i vedle binárky.
    ACQ="$(find . "$(dirname "$QF")" -maxdepth 2 -name acquisition.json \
            -newer "$ZNACKA" -printf '%h\n' 2>/dev/null | head -n1)"
    rm -f "$ZNACKA"
    if [[ -n "$ACQ" ]]; then
      mvt-android check-androidqf -o "$OUT/mvt-androidqf" "$ACQ" \
        > "$OUT/raw/mvt-androidqf.log" 2>&1
    else
      echo "Výstup AndroidQF nenalezen, spusťte check-androidqf ručně."
    fi
  fi

  NALEZY="$(find "$OUT" -name '*_detected.json' 2>/dev/null)"
  if [[ -n "$NALEZY" ]]; then
    zapis "MVT: NALEZENY SHODY se známými indikátory:"
    sed 's/^/  - /' <<<"$NALEZY" | tee -a "$SOUHRN"
  else
    zapis "MVT: žádná shoda se známými indikátory (nezaručuje čistý telefon)."
  fi
else
  zapis "MVT není nainstalováno (pipx install mvt), tento krok byl přeskočen."
fi

# ---------------------------------------------------------------- konec
info "Hotovo"
echo "Souhrn:        $SOUHRN"
echo "Surová data:   $OUT/raw/"
echo "Stažené APK:   $OUT/apk/"
echo
echo "Telefon můžete odpojit a ladění USB vypnout."
