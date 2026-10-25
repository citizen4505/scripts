# scripts

Sbírka mých shellových skriptů pro Linux.

| Skript | Co dělá |
|---|---|
| [`android/kontrola-androidu.sh`](android/kontrola-androidu.sh) | Přes ADB sesbírá data z telefonu s Androidem a hledá známky sledovacích aplikací (stalkerware). Z telefonu jen čte. |
| [`system/swap-expander-interactive.sh`](system/swap-expander-interactive.sh) | Interaktivně vytvoří a aktivuje další swap soubor, volitelně ho zapíše do `/etc/fstab`. |

## Instalace

```bash
git clone https://github.com/UZIVATEL/scripts.git ~/scripts
mkdir -p ~/.local/bin
ln -s ~/scripts/android/kontrola-androidu.sh ~/.local/bin/kontrola-androidu
ln -s ~/scripts/system/swap-expander-interactive.sh ~/.local/bin/swap-expander
```

Pak jdou skripty spustit odkudkoli jménem (`kontrola-androidu`, `swap-expander`).
Aktualizace: `cd ~/scripts && git pull`.

---

## kontrola-androidu.sh

Sběr dat z Androidu přes ADB a offline vyhodnocení na Linuxu.

**Potřebuje:** `adb` (`sudo apt install adb`).
**Volitelně:** [MVT](https://github.com/mvt-project/mvt) (`pipx install mvt`), [AndroidQF](https://github.com/mvt-project/androidqf).

**Na telefonu:** zapnuté *Ladění USB* a potvrzený dialog *Povolit ladění*.

```bash
./kontrola-androidu.sh            # APK stáhne jen u aplikací mimo obchod
./kontrola-androidu.sh --all-apk  # APK stáhne u všech aplikací třetích stran
```

Co kontroluje:

1. aplikace nainstalované mimo obchod,
2. služby přístupnosti, čtení oznámení, správce zařízení,
3. Play Protect, instalaci z neznámých zdrojů, zobrazení přes jiné aplikace,
4. citlivá oprávnění (mikrofon, kamera, poloha, SMS, hovory…),
5. SHA-256 hashe APK s odkazy na VirusTotal (soubory se nikam nenahrávají),
6. bugreport,
7. vyhodnocení pomocí MVT, pokud je nainstalované.

Výsledky se ukládají do složky `kontrola-DATUM-CAS/` v aktuálním adresáři, souhrn je v `SOUHRN.txt`.

> ⚠️ Výstupní složka obsahuje osobní data z telefonu.

---

## swap-expander-interactive.sh

Přidá další swapovací soubor. Ptá se na cestu, velikost a zápis do `/etc/fstab`,
před provedením ukáže souhrn a čeká na potvrzení.

```bash
./swap-expander-interactive.sh
```

- Sám se znovu spustí přes `sudo`, pokud není root.
- Kontroluje volné místo a varuje, když by zbylo méně než 1 GB.
- Na btrfs nastaví soubor bez copy-on-write.
- Když `fallocate` nebo `swapon` selže, zkusí soubor vytvořit přes `dd`.
- Před zápisem do `/etc/fstab` udělá zálohu.
- Při chybě smaže nedokončený soubor.

Odstranění swapu:

```bash
sudo swapoff /swapfile2 && sudo rm /swapfile2
# a smazat odpovídající řádek z /etc/fstab
```

---

## Licence

[MIT](LICENSE)
