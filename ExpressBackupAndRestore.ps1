<#
.SYNOPSIS
    Sincronizzazione database dal server di test a produzione per SQL Server Express.

.DESCRIPTION
    Legge il nome del DB da un file di testo (prima riga: DB sorgente, seconda riga opzionale: nuovo nome DB target), 
    esegue il backup sul sorgente aggirando i controlli file, lo trasferisce sul target via rete (SMB), 
    applica il restore con sovrascrittura, imposta l'owner predefinito, esegue l'eventuale ridenominazione 
    e infine ripulisce i file .bak temporanei di staging.

.AUTHOR
    L3onard80 w/GEMINI 3.1 PRO

.NOTES
    Changelog:
    - 20.05.2026: Creazione script base (lettura config, Backup-DbaDatabase, copia SMB, Restore-DbaDatabase).
    - 21.05.2026: Aggiunto switch -IgnoreFileChecks per bypassare i limiti di permessi OS sul server sorgente.
    - 21.05.2026: Aggiunto Set-DbaDbOwner per forzare l'assegnazione della login (user01) post-ripristino.
    - 21.05.2026: Attivata e consolidata la routine di pulizia dei file .bak nel blocco finally.
    - 21.05.2026: Implementato Rename-DbaDatabase leggendo dinamicamente la seconda riga dal file di configurazione.
    - 21.05.2026: Aggiunto Restore con Replace di db già esistente, Recovery model s shrink log file
    - 27.05.2026: Aggiunto Backup preventivo pre restore.
    - 03.06.2026: Rimosso warning del comando shrink
#>

# Caricamento Modulo
Import-Module dbatools
# Forza la connessione sicura/insecure per la sola sessione in corso
Set-DbatoolsInsecureConnection -SessionOnly

# --- VARIABILI SERVER ---
$SourceServer = "srvtst"
$TargetServer = "srvprd"

# File di testo contenente il nome del database (nella stessa cartella dello script)
$ConfigFile = Join-Path $PSScriptRoot "db2restore.txt"

# Percorsi di staging per i file .bak
$SourceLocalPath = "E:\Backup\Staging"
$TargetNetworkPath = "\\$TargetServer\Staging"
$TargetLocalPath  = "E:\Backup\Staging"  # Come lo vede il server target localmente

# --- LETTURA E CONFIGURAZIONE DATI ---
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Errore: Il file di configurazione '$ConfigFile' non esiste."
    Exit
}

$ConfigLines = Get-Content $ConfigFile
$DbName = $ConfigLines[0].Trim()

# Verifica se c'è una seconda riga per il nuovo nome
$NewDbName = ""
if ($ConfigLines.Count -gt 1 -and (-not [string]::IsNullOrWhiteSpace($ConfigLines[1]))) {
    $NewDbName = $ConfigLines[1].Trim()
}

if ([string]::IsNullOrWhiteSpace($DbName)) {
    Write-Error "Errore: La prima riga del file di configurazione è vuota. Specifica il nome del database."
    Exit
}

$FinalDbName = if ($NewDbName) { $NewDbName } else { $DbName }

Write-Host "==> Avvio processo per il database sorgente: $DbName" -ForegroundColor Cyan
Write-Host "==> Il database target di riferimento sarà : $FinalDbName" -ForegroundColor Cyan

try {
    # 2. Esecuzione del Backup sul server sorgente
    Write-Host "-> Esecuzione del Full Backup su $SourceServer..." -ForegroundColor Yellow
    $BackupResult = Backup-DbaDatabase -SqlInstance $SourceServer -Database $DbName -BackupDirectory $SourceLocalPath -Type Full -ReplaceInName -IgnoreFileChecks
    
    if (-not $BackupResult) { throw "Il backup su $SourceServer è fallito." }
    $BackupFilePath = $BackupResult.Path
    Write-Host "-> Backup creato: $BackupFilePath" -ForegroundColor Green

    # 3. Trasferimento del file .bak sul server target via SMB
    Write-Host "-> Trasferimento del file di backup su $TargetServer..." -ForegroundColor Yellow
    if (-not (Test-Path $TargetNetworkPath)) {
        New-Item -ItemType Directory -Path $TargetNetworkPath -Force | Out-Null
    }
    
    $CopiedFile = Copy-Item -Path $BackupFilePath -Destination $TargetNetworkPath -PassThru -Force
    $TargetBackupFile = Join-Path $TargetLocalPath $CopiedFile.Name
    Write-Host "-> File copiato correttamente nel path del target." -ForegroundColor Green

    # 4. Backup Preventivo (Se il DB esiste già sul target)
    Write-Host "-> Controllo esistenza di '$FinalDbName' per backup preventivo..." -ForegroundColor Yellow
    if (Get-DbaDatabase -SqlInstance $TargetServer -Database $FinalDbName -ErrorAction SilentlyContinue) {
        
        $BackupFolderTarget = "E:\Backup"
        $DateSuffix = Get-Date -Format "yyyyMMdd"
        $BackupFileName = "${FinalDbName}_prerefresh${DateSuffix}.bak"
        
        Write-Host "   - Database '$FinalDbName' esiste già. Esecuzione backup di sicurezza in corso su $BackupFolderTarget\$BackupFileName..." -ForegroundColor DarkYellow
        
        # Esegue il backup sul server target prima di sovrascriverlo
        Backup-DbaDatabase -SqlInstance $TargetServer -Database $FinalDbName -Path $BackupFolderTarget -BackupFilename $BackupFileName -ErrorAction Stop
        
        Write-Host "   - Backup preventivo salvato con successo." -ForegroundColor Green
    } else {
        Write-Host "   - Il database '$FinalDbName' non esiste sul target. Salto il backup preventivo." -ForegroundColor Gray
    }

    # 5. Ripristino e Ridenominazione
    Write-Host "-> Preparazione target: Controllo se il database '$FinalDbName' esiste già per la rimozione..." -ForegroundColor Yellow
    if (Get-DbaDatabase -SqlInstance $TargetServer -Database $FinalDbName -ErrorAction SilentlyContinue) {
        Write-Host "   - Database esistente trovato. Chiusura connessioni e rimozione in corso per sbloccare i file..." -ForegroundColor DarkYellow
        
        # 1. Killa tutte le connessioni attive al database
        Get-DbaProcess -SqlInstance $TargetServer -Database $FinalDbName -ErrorAction SilentlyContinue | Stop-DbaProcess -Confirm:$false -ErrorAction SilentlyContinue
        
        # 2. Elimina il database esistente liberando i file fisici
        Remove-DbaDatabase -SqlInstance $TargetServer -Database $FinalDbName -Confirm:$false -ErrorAction Stop
    }

    Write-Host "-> Ripristino del database su $TargetServer come '$FinalDbName'..." -ForegroundColor Yellow
    Restore-DbaDatabase -SqlInstance $TargetServer -DatabaseName $FinalDbName -Path $TargetBackupFile -WithReplace -ReplaceDbNameInFile -ErrorAction Stop
    Write-Host "-> Backup ripristinato con successo come '$FinalDbName'." -ForegroundColor Green

    # 6. SQL Login proprietaria (se necessario)
    $TargetOwner = "user01" 
    Set-DbaDbOwner -SqlInstance $TargetServer -Database $FinalDbName -Login $TargetOwner -ErrorAction Stop
    Write-Host "-> Owner del database impostato correttamente su: $TargetOwner" -ForegroundColor Green

    # 7. Impostazione Recovery Model
    Write-Host "-> Impostazione del Recovery Model su 'Simple'..." -ForegroundColor Yellow
    Set-DbaDbRecoveryModel -SqlInstance $TargetServer -Database $FinalDbName -RecoveryModel Simple -Confirm:$false -ErrorAction Stop
    Write-Host "-> Recovery Model impostato correttamente su 'Simple'." -ForegroundColor Green

    # 8. Shrink del file di Log
    Write-Host "-> Esecuzione dello shrink del file di Log..." -ForegroundColor Yellow
    Invoke-DbaDbShrink -SqlInstance $TargetServer -Database $FinalDbName -FileType Log -ErrorAction Stop -WarningAction SilentlyContinue
    Write-Host "-> Shrink del file di Log completato con successo." -ForegroundColor Green

    Write-Host "==> PROCESSO COMPLETATO CON SUCCESSO SU $TargetServer!" -ForegroundColor Green

} catch {
    Write-Error "Si è verificato un errore critico durante il processo: $_"

} finally {
    # La pulizia parte solo se avevamo almeno letto il nome del DB dal file
    if (-not [string]::IsNullOrWhiteSpace($DbName)) {
        Write-Host "-> Avvio pulizia dei file di staging..." -ForegroundColor Cyan

        if ($null -ne $BackupFilePath -and (Test-Path $BackupFilePath -ErrorAction SilentlyContinue)) {
            Remove-Item -Path $BackupFilePath -Force -ErrorAction SilentlyContinue
            Write-Host "   - Rimosso backup dal sorgente." -ForegroundColor Gray
        }

        if ($null -ne $BackupFilePath) {
            $FileNameOnly = Split-Path $BackupFilePath -Leaf
            $StaticTargetNetworkPath = Join-Path $TargetNetworkPath $FileNameOnly

            if (Test-Path $StaticTargetNetworkPath -ErrorAction SilentlyContinue) {
                Remove-Item -Path $StaticTargetNetworkPath -Force -ErrorAction SilentlyContinue
                Write-Host "   - Rimosso backup dal target." -ForegroundColor Gray
            }
        }
    }
}
