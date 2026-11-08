# NASPI · VERGEN TECHNOLOGY

NAS minimale per Raspberry Pi (anche **Pi 1**): cartella condivisa Samba `\\mariarosaria\nas`
su SSD/HDD USB, accesso da fuori casa con Tailscale.

## Installazione (un comando)

Su Raspberry Pi OS **Lite** appena installato, collegato in rete:

```bash
curl -fsSL https://raw.githubusercontent.com/vergen-developer/naspi/main/install.sh | sudo bash
```

oppure dal repo clonato: `sudo bash install.sh`. Nessuna domanda; rilanciabile quando vuoi.
Alla fine stampa utente, password e link di login Tailscale. Riavvia una volta se lo chiede.

Opzioni: `sudo NASPI_HOSTNAME=casa TAILSCALE_AUTHKEY=tskey-... bash install.sh`
(vedi l'intestazione di `install.sh`).

## SSD USB

- Collegalo quando vuoi: si monta da solo su `/srv/nas` (ext4, exFAT, NTFS, FAT).
- Disco **nuovo/vuoto** → formattato ext4 in automatico. Un disco con dati non viene mai cancellato.
- Cancellare e riformattare: `sudo naspi format`.

### Pi 1: alimentazione (obbligatorio)

Le porte USB del Pi 1 non reggono un SSD: al collegamento la tensione crolla e il Pi
**si riavvia** o il disco **sparisce/ricompare**. Nessun software lo risolve. Serve:

- alimentatore **5 V ≥ 2.5 A** di qualità (cavo corto e spesso);
- SSD su **hub USB alimentato** (o cavo Y con secondo alimentatore).

`sudo naspi diag` mostra se c'è sotto-tensione, gli errori USB e la fine dell'avvio precedente.

## Pannello web

Da qualsiasi PC o telefono in casa: **http://mariarosaria.local** — spazio libero, stato
dell'SSD, alimentazione, accesso remoto e percorsi da copiare. Si aggiorna ogni minuto,
tema chiaro/scuro automatico. Non mostra la password.

Al login SSH compare un riepilogo grafico dello stato.

## Comandi

| Comando | Cosa fa |
|---|---|
| `sudo naspi` | riepilogo: percorsi, utente, password, stato |
| `sudo naspi login` | nuovo link Tailscale |
| `sudo naspi diag` | diagnosi alimentazione / SSD / servizi |
| `sudo naspi mount` | rimonta l'SSD |
| `sudo naspi format` | cancella e formatta l'SSD in ext4 |
| `sudo naspi web` | aggiorna subito il pannello web |

## Windows

`windows\backup-desktop.bat`: copia il Desktop su `\\mariarosaria\nas\backup\<PC>\Desktop`.

---

**VERGEN TECHNOLOGY** · NASPI v6.0
