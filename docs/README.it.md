🌐 [English](../README.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · **Italiano** · [Português](README.pt.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md)

# M365 MFA Administration Tool

Con questo strumento, amministratori e help desk configurano l'**autenticazione a più fattori (MFA) per conto di altri utenti** – ad esempio una chiave FIDO2, una scheda TOTP o un codice di accesso temporaneo. Inoltre mostra a colpo d'occhio quanto è protetto un account utente.

> [!NOTE]
> Gli screenshot mostrano l'interfaccia in inglese. L'interfaccia può essere impostata in italiano in alto a destra.

![Finestra principale di M365 MFA Administration Tool](images/en/main-window.png)

## Indice

- [In breve](#in-breve)
- [Avvio rapido](#avvio-rapido)
- [Guida passo per passo](#guida-passo-per-passo)
- [Quale metodo scegliere](#quale-metodo-scegliere)
- [Creare un account di emergenza](#creare-un-account-di-emergenza)
- [Domande frequenti e risoluzione dei problemi](#domande-frequenti-e-risoluzione-dei-problemi)
- [Sicurezza](#sicurezza)
- [Requisiti e autorizzazioni per gli amministratori](#requisiti-e-autorizzazioni-per-gli-amministratori)
- [Struttura del progetto](#struttura-del-progetto)
- [Aggiungere una lingua](#aggiungere-una-lingua)

---

## In breve

| | Funzione |
|---|---|
| 🔍 | **Cercare utenti** – per nome, indirizzo e-mail, UPN o ID oggetto |
| 🚦 | **Semaforo MFA** – mostra subito se un account è protetto bene, debolmente o per niente, con una raccomandazione |
| 👑 | **Ruoli di amministratore** – mostra se l'utente ha diritti amministrativi |
| 📋 | **Visualizzare ed eliminare metodi MFA** – tutti i metodi registrati con data e dettagli |
| ➕ | **Configurare metodi** – chiave FIDO2, schede TOTP, Temporary Access Pass e MFA fittizia |
| 🆘 | **Account di emergenza** – creare un accesso di emergenza (break-glass) con chiave FIDO2 e password sconosciuta |
| 🌐 | **Multilingue** – inglese (predefinito), tedesco, spagnolo, francese, italiano, portoghese, olandese e polacco |

---

## Avvio rapido

1. Copiare l'intera cartella sul proprio computer (i file devono restare insieme).
2. **Fare doppio clic su `Start.cmd`.**
3. In alto a destra impostare la lingua su **Italiano** e fare clic su **"Accedi"**. Accedere con il proprio account amministratore.

> [!TIP]
> Per un accesso rapido, creare un collegamento sul desktop a `Start.cmd` (clic destro → *Crea collegamento*).

Al primo accesso lo strumento verifica se mancano componenti necessari. In tal caso li elenca e chiede una sola volta se installarli – l'installazione avviene in background (circa uno o due minuti) ed è visibile nel log. Poi Microsoft chiede una sola volta il consenso alle autorizzazioni dello strumento.

---

## Guida passo per passo

### 1. Scegliere la lingua e accedere

L'interfaccia si avvia in **inglese**. Con la casella di selezione in alto a destra, accanto a "Sign in", la lingua può essere cambiata in qualsiasi momento, senza riavvio. La scelta viene salvata per il proprio utente Windows e applicata all'avvio successivo.

Fare clic su **"Accedi"** in alto a destra. Dopo l'accesso viene mostrato in verde *"Connesso come …"* insieme al tenant. **"Esci"** termina la sessione – ciò avviene anche automaticamente alla chiusura della finestra.

### 2. Cercare un utente

Nella casella **"1. Cerca utente"** digitare l'inizio di un nome, di un indirizzo e-mail o dell'UPN e premere **Invio** (oppure fare clic su **"Cerca"**).

- **Un risultato:** l'utente viene aperto direttamente.
- **Più risultati:** sotto la casella di ricerca si apre un elenco – fare clic sull'utente desiderato. Con **Esc** o un clic altrove l'elenco si chiude.

### 3. Capire lo stato MFA

A destra, in **"Utente selezionato"**, il **semaforo MFA** mostra quanto è protetto l'account:

| Semaforo | Significato | Cosa fare? |
|---|---|---|
| 🟢 **MFA forte (resistente al phishing)** | Chiave FIDO2, passkey o Windows Hello presente | Tutto a posto. |
| 🟢 **MFA forte** | App Authenticator o scheda/app TOTP presente | Va bene. Per gli amministratori è consigliato anche FIDO2. |
| 🟡 **Solo MFA debole** | Solo SMS o chiamata | Configurare un metodo migliore, poi rimuovere SMS/chiamata. |
| 🟡 **Solo MFA fittizia** | L'account è bloccato per sicurezza (vedi [MFA fittizia](#quale-metodo-scegliere)) | Configurare un metodo reale per poterlo usare. |
| 🟡 **Solo Temporary Access Pass** | Solo un codice di accesso temporaneo | L'utente deve ora usarlo per configurare un metodo permanente. |
| 🔴 **Nessuna MFA – solo password** | Nessun secondo fattore | Configurare un metodo con urgenza. |

Sotto il semaforo compaiono raccomandazioni concrete, ad esempio *"Sono registrati anche SMS/chiamata, che possono essere rimossi"*.

Più in basso, **"Ruoli amministrativi"** indica se l'utente ha diritti di amministratore. **"Mostra"** espande l'elenco. Per ogni ruolo è indicato anche se è attivo in modo permanente, assegnato tramite un gruppo o solo attivabile tramite PIM.

### 4. Visualizzare ed eliminare i metodi MFA

A sinistra, in **"2. Metodi MFA registrati"**, sono elencati tutti i metodi dell'utente. Facendo clic su un metodo vengono mostrati sotto **tutti i dettagli** (ad es. modello del dispositivo, numero di serie, data di creazione).

Per eliminare un metodo, selezionarlo e fare clic su **"Elimina metodo"**. Prima dell'eliminazione viene chiesta una conferma. La password non può essere eliminata.

> [!NOTE]
> Microsoft applica le modifiche con alcuni secondi di ritardo. Lo strumento attende automaticamente che l'elenco mostri il nuovo stato. Se necessario, fare clic su **"Aggiorna"**.

### 5. Configurare un nuovo metodo

A destra, in **"3. Configura metodo"**, scegliere il metodo desiderato:

![Selezione del metodo MFA](images/en/select-method.png)

A seconda del metodo compaiono i campi appropriati (ad es. il numero di serie) e una breve indicazione. Fare quindi clic su **"Avvia configurazione"** e confermare. Il risultato appare nel **log** e l'elenco dei metodi viene aggiornato automaticamente.

---

## Quale metodo scegliere

| Metodo | Quando usarlo? | Cosa succede? |
|---|---|---|
| **Chiave di sicurezza FIDO2** | L'utente riceve una chiave FIDO2 (ad es. YubiKey). Il metodo più sicuro – soprattutto per gli amministratori. | Inserire la chiave e il numero di serie. Windows chiede il **PIN** della chiave e di **toccarla**. La chiave si chiamerà `FIDO2-<numero di serie>`. |
| **Scheda TOTP con segreto fisso** | L'utente riceve una scheda di codici il cui segreto è fornito dal produttore. | Inserire numero di serie e segreto. La scheda viene creata, assegnata all'utente e attivata subito. |
| **Scheda TOTP programmabile** | L'utente riceve una scheda di codici da programmare in autonomia (ad es. con l'app del produttore). | Inserire il numero di serie. Lo strumento genera un nuovo segreto e mostra **codice QR e segreto**. Programmare la scheda, poi chiudere la visualizzazione con ✕. |
| **Temporary Access Pass (TAP)** | L'utente deve configurare da sé Authenticator o una passkey ma non ha ancora alcun metodo – oppure l'ha perso. | Viene generato un codice **valido da subito per 2 ore** e utilizzabile più volte. È mostrato in grande in un riquadro giallo e può essere copiato. Un TAP esistente viene sostituito. |
| **MFA fittizia** | Si vuole proteggere un account che (ancora) nessuno usa – ad es. un nuovo account di emergenza o di servizio. | Viene registrato un metodo a codice la cui chiave viene distrutta subito. All'accesso viene richiesta un'MFA che nessuno può soddisfare – così l'account è protetto. |

> [!IMPORTANT]
> **TAP, segreti e codici QR vengono mostrati una sola volta.** Non compaiono nel log e non possono essere recuperati in seguito. Se un codice QR viene salvato con "Salva codice QR …", il file contiene il segreto – eliminarlo dopo la programmazione.

---

## Creare un account di emergenza

Un **account di emergenza (break-glass)** è un accesso di emergenza che consente di entrare nel tenant anche quando i normali accessi amministrativi non funzionano (ad es. per un criterio di accesso condizionale errato).

Fare clic su **"Account di emergenza …"** in alto a destra:

![Finestra "Crea account di emergenza"](images/en/breakglass-dialog.png)

1. Selezionare il **dominio** in cui creare l'account.
2. Decidere se l'account riceve il ruolo **Global Administrator** (consigliato, preselezionato).
3. Inserire la **chiave FIDO2** e il suo numero di serie.
4. Fare clic su **"Crea account"**.

Lo strumento esegue poi automaticamente:

- crea l'account con una **password casuale** (255 caratteri – non viene mai mostrata né salvata, nessuno la conosce)
- imposta come nome dell'account l'ID oggetto univoco
- assegna il ruolo Global Administrator
- protegge subito l'account con una **MFA fittizia**
- **registra la chiave FIDO2** (Windows chiede PIN e tocco) e poi rimuove di nuovo la MFA fittizia

Alla fine un riepilogo mostra le operazioni eseguite e il nuovo account viene visualizzato direttamente.

> [!WARNING]
> **Poi completare manualmente:**
> - **Escludere** l'account **da tutti i criteri di accesso condizionale**.
> - Configurare un **avviso di accesso** per notare ogni utilizzo.
> - Conservare la chiave FIDO2 in un luogo sicuro (ad es. in cassaforte).

Se la registrazione FIDO2 non riesce o viene annullata, l'account resta protetto dalla MFA fittizia. La chiave può essere aggiunta in seguito tramite **"3. Configura metodo → Chiave di sicurezza FIDO2"**.

---

## Domande frequenti e risoluzione dei problemi

**Il doppio clic su `Start.cmd` non fa nulla o mostra un errore.**
Lo strumento funziona solo su Windows. Se la cartella è stata copiata da Internet, Teams o un file ZIP, i file potrebbero essere bloccati. Eseguire una volta in PowerShell nella cartella: `Get-ChildItem -Recurse | Unblock-File`.

**L'accesso chiede di nuovo il consenso.**
È normale quando una nuova funzione richiede autorizzazioni aggiuntive – ad esempio per il primo account di emergenza.

**Un metodo appena creato o eliminato non viene mostrato subito.**
Microsoft ha bisogno di alcuni secondi. Lo strumento attende automaticamente fino a circa 16 secondi; poi, se necessario, fare clic su **"Aggiorna"**.

**FIDO2: "Fido credential policy …" o "non abilitato".**
FIDO2 non è abilitato nel tenant. Un amministratore deve abilitarlo nei criteri dei metodi di autenticazione (vedi [requisiti](#requisiti-e-autorizzazioni-per-gli-amministratori)).

**FIDO2: "L'UPN è troppo lungo".**
FIDO2 consente al massimo 64 caratteri per il nome di accesso (UPN).

**Scheda TOTP: "Un token con il numero di serie … è già assegnato a …".**
La scheda appartiene già a un altro utente. Rimuoverla prima da lì.

**Messaggio di errore con "Authorization_RequestDenied" o "Forbidden".**
Al proprio account manca un ruolo di amministratore (vedi [ruoli](#requisiti-e-autorizzazioni-per-gli-amministratori)).

Ogni azione è riportata con l'ora nel **log** in basso a destra. Viene inoltre salvata subito in un file di log giornaliero nella cartella dello strumento, ad es. `Logs\2026-10-12.log` (se la cartella non è scrivibile: `%LOCALAPPDATA%\M365MfaTool\Logs`) – utile in caso di domande.

---

## Sicurezza

- **Nessun segreto nel log:** TAP, segreti e password non vengono mai registrati né salvati su disco.
- **Password sconosciute:** le password degli account di emergenza sono generate casualmente e mai mostrate.
- **Conferme:** ogni modifica deve essere confermata; le conferme sono impostate su "No" per impostazione predefinita.
- **Pulizia in caso di errore:** se la configurazione di una scheda TOTP non riesce, lo strumento rimuove automaticamente le voci create a metà.

> [!CAUTION]
> Eseguire azioni amministrative solo secondo il proprio processo interno di approvazione e sicurezza.

---

## Requisiti e autorizzazioni per gli amministratori

### Requisiti di sistema

- Windows con **Windows PowerShell 5.1** (preinstallato; PowerShell 7 non è supportato perché l'interfaccia usa WPF)
- Accesso a Internet al primo avvio per installare i moduli PowerShell (solo per l'utente corrente, senza diritti di amministratore):
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Identity.SignIns` e `DSInternals.Passkeys` **1.0.6** (FIDO2)
  - `QRCodeGenerator` (codici QR per schede TOTP programmabili)

  In alternativa installarli in anticipo con `Install-Prerequisites.ps1`.
- Per FIDO2 la chiave deve essere collegata al **computer locale** (tramite RDP solo con reindirizzamento WebAuthn).

### Autorizzazioni Graph (delegate)

All'accesso:

| Autorizzazione | Scopo |
|---|---|
| `User.Read.All` | Cercare utenti |
| `UserAuthenticationMethod.Read.All` | Mostrare i metodi MFA |
| `UserAuthenticationMethod.ReadWrite.All` | Configurare ed eliminare metodi MFA |
| `Policy.ReadWrite.AuthenticationMethod` | Creare/eliminare schede TOTP e MFA fittizia nell'inventario dei token |
| `RoleManagement.Read.Directory` | Mostrare i ruoli di amministratore di un utente |

In aggiunta, al primo account di emergenza:

| Autorizzazione | Scopo |
|---|---|
| `User.ReadWrite.All` | Creare utenti |
| `Domain.Read.All` | Mostrare i domini da selezionare |
| `RoleManagement.ReadWrite.Directory` | Assegnare Global Administrator |

### Ruoli Entra necessari per il proprio account

| Attività | Ruolo |
|---|---|
| Gestire i metodi degli utenti normali, TAP | **Authentication Administrator** |
| Gestire i metodi degli amministratori | **Privileged Authentication Administrator** |
| Schede TOTP e MFA fittizia | in aggiunta **Authentication Policy Administrator** |
| Account di emergenza | **Global Administrator** (oppure Privileged Role Administrator + User Administrator) |

### Impostazioni del tenant

Nei **criteri dei metodi di autenticazione** (Interfaccia di amministrazione di Entra → Protezione → Metodi di autenticazione) devono essere abilitati i metodi usati:

- **Passkey (FIDO2)**
- **Token OATH hardware** (per schede TOTP e MFA fittizia)
- **Temporary Access Pass** – durata massima di almeno 2 ore

### Note

- Alcune funzioni usano l'**API beta** di Microsoft Graph (ad es. per i token OATH hardware), che può cambiare.
- I ruoli idonei tramite PIM vengono mostrati solo con Entra ID P2.
- La lingua scelta viene salvata in `%APPDATA%\M365MfaTool\settings.json`.

---

## Struttura del progetto

| File | Contenuto |
|---|---|
| `Start.cmd` | Avvio con doppio clic |
| `Start-M365MfaTool.ps1` | Interfaccia, gestione dello stato ed eventi |
| `UI/MainWindow.xaml` | Layout della finestra principale |
| `UI/BreakGlassDialog.xaml` | Finestra per i nuovi account di emergenza |
| `Modules/Graph.psm1` | Accesso, richieste Graph, utenti, domini, ruoli, semaforo MFA, lettura/eliminazione dei metodi |
| `Modules/Provisioning.psm1` | Configurazione di FIDO2, schede TOTP, MFA fittizia, TAP e account di emergenza |
| `Modules/Localization.psm1` | Multilingua: carica i file di lingua e fornisce i testi |
| `Languages/*.json` | Testi per lingua (`en.json` è il riferimento) |
| `Install-Prerequisites.ps1` | Installazione preliminare facoltativa di tutti i moduli |
| `docs/` | Documentazione tradotta e screenshot |
| `Logs/` | File di log giornalieri (creati automaticamente, non salvati in Git) |

---

## Aggiungere una lingua

1. Copiare `Languages/en.json` e rinominarlo con il codice della lingua, ad es. `sv.json` per lo svedese.
2. Impostare `"_language"` sul nome della lingua nella lingua stessa (ad es. `"Svenska"`) e tradurre tutti i testi. I segnaposto come `{0}` devono essere mantenuti.
3. Riavviare lo strumento – la lingua compare automaticamente nella selezione. I testi mancanti vengono mostrati in inglese.
4. Facoltativo: aggiungere una documentazione tradotta come `docs/README.<codice>.md` e collegarla nella barra delle lingue in cima a tutti i file README.
