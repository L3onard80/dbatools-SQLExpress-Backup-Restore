# SQL Server Express Backup & Restore (via dbatools)

Questo script PowerShell automatizza l'intero ciclo di vita del refresh (rinfresco) di un database SQL Server da un ambiente sorgente (Test/Staging) a un ambiente di destinazione (Produzione/Target/QA), garantendo al contempo la massima sicurezza grazie a backup preventivi e pulizia automatica dei file temporanei.

Lo script si basa interamente sul modulo open-source **dbatools**, garantendo performance elevate e gestione nativa delle logiche di backup/restore di SQL Server.

## 🚀 Funzionalità

Il processo segue una pipeline strutturata in 8 passaggi sequenziali:

1. **Lettura Configurazione Dinamica:** Identifica il database da processare ed un eventuale nuovo nome tramite un file di testo esterno.
2. **Backup Logico sul Sorgente:** Esegue un `Full Backup` del database sul server sorgente.
3. **Trasferimento via SMB:** Copia in modo sicuro il file `.bak` generato all'interno della cartella di staging del server target.
4. **Safety Net (Backup Preventivo):** Se il database esiste già sul server di destinazione, ne esegue un backup di sicurezza in una cartella locale con suffisso temporale (`_prerefreshYYYYMMDD.bak`) prima di effettuare modifiche.
5. **Drop & Free Files:** Identifica e disconnette tutte le connessioni attive sul database target per sbloccare i file fisici (`.mdf`/`.ldf`) e ne esegue la rimozione pulita.
6. **Ripristino e Ridenominazione:** Ripristina il nuovo database applicando, se richiesto, il nuovo nome e riallineando i file fisici sul disco.
7. **Post-Restore Hardening:**
   - Imposta il corretto SQL Login come proprietario (`Owner`).
   - Modifica il Recovery Model su `Simple` (ideale per ambienti non di produzione o storage controllato).
   - Esegue lo `Shrink` del solo file di log (`.ldf`) per recuperare lo spazio immediatamente.
8. **Pulizia Automatica (Finally):** Cancella i file `.bak` di staging sia sul server sorgente che sul target, lasciando i dischi puliti.

---

## 🛠️ Prerequisiti

* **PowerShell 7+**
* **Modulo dbatools** installato sulla macchina che esegue lo script:
```powershell
Install-Module -Name dbatools -Scope AllUsers -Force
```
* **Permessi di rete (SMB):** L'utente che esegue lo script (o gli account di servizio SQL Server) deve disporre di permessi di lettura/scrittura sulle share di staging.

---

## ⚙️ Configurazione

Lo script non richiede la modifica del codice sorgente per cambiare database. Legge i parametri dal file **`db2restore.txt`** posizionato nella stessa cartella dello script.

### Struttura del file `db2restore.txt`
* **Riga 1:** Nome del database sul server sorgente (Obbligatorio).
* **Riga 2:** Nome che il database dovrà assumere sul server target (Opzionale. Se lasciata vuota o omessa, manterrà lo stesso nome del sorgente).

#### Esempio 1: Refresh mantenendo lo stesso nome
```text
MyDB
```

#### Esempio 2: Refresh con ridenominazione sul target
```text
MyDB
MyDB_New
```

---

## 💻 Utilizzo

1. Apri il terminale PowerShell.
2. Naviga nella cartella dello script.
3. Configura il file `db2restore.txt`.
4. Lancia lo script:
```powershell
.\RestoreFromTST.ps1
```

---

## 🛡️ Gestione Errori e Sicurezza

* **Fail-Safe sul Nome DB:** Se per errore il file di configurazione dovesse presentare righe vuote o corrotte, lo script interrompe immediatamente l'esecuzione prima di interrogare SQL Server, evitando azioni massive indesiderate.
* **Connessioni Insicure:** Lo script include la direttiva `Set-DbatoolsInsecureConnection -SessionOnly` per gestire correttamente l'esecuzione in ambienti aziendali con certificati SQL autocertificati senza bloccare l'automazione.
* **Integrità dei Dati:** In caso di errore critico in una qualsiasi delle fasi, il blocco `catch` intercetta l'eccezione stampando l'errore a schermo, mentre il blocco `finally` garantisce comunque la rimozione dei file di staging per non saturare i dischi.
