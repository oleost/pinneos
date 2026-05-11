# SimpleHomeLab — Prosjektbeskrivelse

## Overordnet mål

Et lettvekts Linux-system som booter fra USB og overlater all "intelligens" til et ZFS-volum på tilkoblet lagring. Målet er at selve USB-pinnen er utbyttbar — alt som gjør systemet til *ditt* system bor på disken.

Backup og restore skal være så enkelt at det å flytte harddisker og koble til en ny USB-pinne er nok til å få alt tilbake — på samme eller ny hardware.

---

## Målgruppe

- Homelab-entusiaster med teknisk bakgrunn
- Kjenner til: BIOS-boot, hva Docker er, grunnleggende Linux
- Skal likevel oppleves som enkelt og veiledet

---

## Kjerneprinsipp

- **USB = boot-medie, ikke system.** Pinnen inneholder kun det som trengs for å starte og koble til ZFS-poolen.
- **ZFS = hjernen.** Konfigurasjon, apper og data bor her — ikke på pinnen.
- **Gjenopprett = flytt disker + koble til USB.** Ingen reinstallasjon, ingen tap av konfigurasjon.
- **Hardware-uavhengig.** Systemet skal fungere på ny hardware så lenge diskene og USB følger med.

---

## Teknologistack

| Komponent | Valg | Begrunnelse |
|---|---|---|
| Linux-base | Arch Linux (archiso) | systemd-native = Cockpit fungerer. ZFS fra archzfs-linux-lts bygges én gang i Docker-containeren og bakes inn. Kernel er låst i imaget — ingen rolling-release-risiko. |
| Bootloader | GRUB 2 (hybrid BIOS+UEFI) | systemd-boot støtter kun UEFI. Homelab-hardware er ofte eldre. GRUB søker etter disk via label uansett USB-port. |
| Root-filsystem | SquashFS (zstd) + overlayfs på tmpfs | Standard live-boot-mønster. All skriving går til RAM. USB-pinnen er aldri i bruk etter boot. |
| ZFS | OpenZFS via archzfs-linux-lts, kompilert ved image-bygging | Moduler bakes inn i imaget. Ingen live-kompilering ved boot. Import skjer i userspace via systemd-tjeneste. |
| Containers | Docker + overlay2 på dedikert ZFS-dataset | Dockerens native ZFS storage driver er deprecated (Docker 25+). overlay2 på ZFS-dataset er beste av begge verdener. |
| Systempanel | Cockpit (port 9090) | Socket-aktivert, ~0 MB idle, utvidbar med custom plugins. |
| ZFS-administrasjon | Eget lite Cockpit-plugin | cockpit-zfs-manager har usikkert vedlikehold — kontrollert kode er tryggere. |
| Docker-styring | Dockge (port 5001) | ~30 MB idle, fil-basert (compose-filer på disk), enkel og fokusert. |
| Startside | Homepage (port 80) | YAML-konfig, Docker-aware widgets, aktivt vedlikeholdt per 2025. |
| Image-bygging | Alpine mkimg / mkimage.sh | Offisielt Alpine-verktøy, produserer små images raskt. |

---

## Dataset-struktur

```
pool/
  system/    ← OS-konfigurasjon, innstillinger, tjenesteoppsett
  apps/      ← Docker-data (montert på /var/lib/docker med xattr=sa, acltype=posixacl)
  storage/   ← brukerdata tilgjengelig for apper og tjenester
```

---

## USB-layout: A/B-partisjonsskjema

Inspirert av ChromeOS, Android og TrueNAS. Gir atomiske oppdateringer med automatisk rollback.

```
USB-partisjonering:
  sda1  FAT32   512MB   EFI + GRUB (bootloader, delt)
  sda2  ext4    2GB     Slot A — squashfs + vmlinuz + initramfs
  sda3  ext4    2GB     Slot B — squashfs + vmlinuz + initramfs
  sda4  F2FS    ~rest   Persist — grubenv, logger, lbu-overlay
```

- GRUB leser en variabel i `grubenv` (på sda4) for å velge hvilken slot som bootes
- `F2FS` på Persist-partisjonen (bedre wear leveling enn ext4 for USB-flash)
- Boot-teller i `grubenv`: feiler en oppdatering, ruller GRUB automatisk tilbake til forrige slot

---

## Boot-flyt

1. USB starter minimal Alpine Linux-kjerne inn i RAM (SquashFS + overlayfs)
2. System oppdager tilkoblede disker
3. `zfs-import-scan.service` kjøres i userspace (etter boot, ikke i initramfs) og importerer pool automatisk
4. Datasett monteres — system er klart

### Ingen pool funnet — Recovery Mode

Hvis systemet ikke finner en gjenkjennbar ZFS-pool ved oppstart, starter det i en **recovery/verktøy-modus** der brukeren kan:
- Lete etter og importere eksisterende pools
- Reparere en skadet pool
- Opprette en ny pool fra scratch

---

## ZFS-oppsett: Viktige detaljer

- **hostid** settes statisk ved image-bygging (`zgenhostid`) — unngår "pool tilhørte annen maskin"-feil
- Bruk `/dev/disk/by-id/` når pool opprettes — stabilt uavhengig av port/rekkefølge
- `zfs-import-scan.service` (ikke cache-basert import) — mer robust på tvers av reboots og hardware
- Docker-dataset opprettes slik:
  ```bash
  zfs create -o mountpoint=/var/lib/docker \
             -o xattr=sa \
             -o acltype=posixacl \
             tank/apps
  ```

---

## Flerpool-støtte og pool-migrering

- Systemet støtter flere ZFS-pools (RAID-oppsett)
- Brukeren kan velge hvilken pool som er **main** (inneholder system + apps)
- Innebygd funksjon for å velge ny main-pool: systemet kopierer sømløst over via ZFS Send/Receive og bytter til den nye
- Nyttig ved oppgradering av disker eller ved flytt til ny maskin

---

## USB-oppdatering

- USB-imaget hentes fra **GitHub Releases** (open source)
- Manuelt trykk i webpanelet for å sjekke og oppdatere
- Oppdateringsflyt:
  1. Laster ned nytt image fra GitHub Releases API
  2. Verifiserer SHA256-sjekksummen
  3. Skriver til inaktiv slot (A eller B)
  4. Bytter `boot_slot` i `grubenv` (atomisk — én skriving)
  5. Reboot → ny slot tas i bruk
- Feiler oppstart 2 ganger: GRUB ruller automatisk tilbake til forrige slot
- Alle kan lage sitt eget USB-image fra kildekoden

---

## USB-redundans: Dual USB

- Støtte for **to USB-pinner** tilkoblet samtidig
- Pinne 1 = master (1. prioritet i BIOS)
- Pinne 2 = backup (2. prioritet i BIOS)
- Systemet gjenkjenner backup via UUID (lagret ved første oppsett) + udev-regler
- Backup synkroniseres automatisk **24 timer etter** master er oppdatert
  - Gir et naturlig rollback-vindu hvis en oppdatering er problematisk

---

## Webpanel: Administrasjonslagene

```
http://homelab.local       → Homepage (oversikt, lenker til alt)
http://homelab.local:9090  → Cockpit (system, disk, nettverk, ZFS-plugin)
http://homelab.local:5001  → Dockge (Docker Compose-stack-styring)
```

---

## Applikasjoner

- Primært **server-apper** (medieserver, hjemmeautomasjon, fildeling, etc.)
- Kjøres som Docker-kontainere lagret på ZFS (`apps/`)
- Brukeren velger selv hva som installeres — ingen kurert liste (i utgangspunktet)
- Tailscale tilbys som en valgfri app for remote-tilgang — ikke tvunget på alle brukere

---

## Første gangs oppsett: To-fase wizard

### Fase 1 — TUI (Python + Textual, på konsoll)
Det som må på plass før noe annet kan fungere:
1. Nettverksoppsett (DHCP eller statisk IP)
2. Hostname + mDNS-navn (`homelab.local`)
3. Admin-passord eller SSH-nøkkel (ev. import fra GitHub: `ssh-import-id gh:brukernavn`)

### Fase 2 — Web (Cockpit på port 9090, nås fra laptop i nettleseren)
Oppgaver som er lettere med et grafisk grensesnitt:
1. Disk-oppdagelse og ZFS pool-oppretting eller -import
2. Dataset-struktur settes opp
3. Backup USB registreres (UUID lagres)
4. Tjenester aktiveres

---

## Utenfor scope (foreløpig)

- ARM / Raspberry Pi (vurderes i v2)
- Multi-bruker
- Kurert app-liste

---

## Hva dette *ikke* er

- Ikke en erstatning for full desktop-Linux
- Ikke en NAS-distro med proprietær logikk (TrueNAS-stil)
- Ikke avhengig av internett-tjenester for å fungere
