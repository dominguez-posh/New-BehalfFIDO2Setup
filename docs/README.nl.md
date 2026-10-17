🌐 [English](../README.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Português](README.pt.md) · **Nederlands** · [Polski](README.pl.md)

# M365 MFA Administration Tool

Met deze tool richten beheerders en helpdeskmedewerkers **meervoudige verificatie (MFA) in namens andere gebruikers** – bijvoorbeeld een FIDO2-sleutel, een TOTP-kaart of een tijdelijke toegangscode. Daarnaast toont de tool in één oogopslag hoe goed een gebruikersaccount is beveiligd.

> [!NOTE]
> De schermafbeeldingen tonen de Engelse interface. Rechtsboven kunt u de interface op Nederlands zetten.

![Hoofdvenster van de M365 MFA Administration Tool](images/en/main-window.png)

## Inhoud

- [In het kort](#in-het-kort)
- [Snel aan de slag](#snel-aan-de-slag)
- [Stap voor stap](#stap-voor-stap)
- [Welke methode kiezen](#welke-methode-kiezen)
- [Een noodaccount aanmaken](#een-noodaccount-aanmaken)
- [MFA-handleiding per e-mail](#mfa-handleiding-per-e-mail)
- [MFA-rapport voor de tenant](#mfa-rapport-voor-de-tenant)
- [Veelgestelde vragen en probleemoplossing](#veelgestelde-vragen-en-probleemoplossing)
- [Beveiliging](#beveiliging)
- [Vereisten en machtigingen voor beheerders](#vereisten-en-machtigingen-voor-beheerders)
- [Projectstructuur](#projectstructuur)
- [Een taal toevoegen](#een-taal-toevoegen)

---

## In het kort

| | Functie |
|---|---|
| 🔍 | **Gebruikers zoeken** – op naam, e-mailadres, UPN of object-ID |
| 🚦 | **MFA-stoplicht** – toont direct of een account goed, zwak of helemaal niet is beveiligd, met een aanbeveling |
| 👑 | **Beheerdersrollen** – toont of de gebruiker beheerdersrechten heeft |
| 📋 | **MFA-methoden bekijken en verwijderen** – alle geregistreerde methoden met datum en details |
| ➕ | **Methoden inrichten** – FIDO2-sleutel, TOTP-kaarten, Temporary Access Pass en nep-MFA |
| ✉️ | **MFA-handleiding per e-mail** – stuurt gebruikers zonder of met zwakke MFA een stapsgewijze handleiding voor de Microsoft Authenticator-app, in hun taal en met voorbeeld |
| 📊 | **MFA-rapport voor de tenant** – MFA-status en laatste aanmelding van alle gebruikers als stoplicht, met zoeken, filters en Excel-export in kleur |
| 🆘 | **Noodaccount** – een noodtoegang (break-glass) met FIDO2-sleutel en onbekend wachtwoord aanmaken |
| 🌐 | **Meertalig** – Engels (standaard), Duits, Spaans, Frans, Italiaans, Portugees, Nederlands en Pools |

---

## Snel aan de slag

1. Kopieer de volledige map naar uw computer (de bestanden moeten bij elkaar blijven).
2. **Dubbelklik op `Start.cmd`.**
3. Zet rechtsboven de taal op **Nederlands** en klik op **"Aanmelden"**. Meld u aan met uw eigen beheerdersaccount.

> [!TIP]
> Maak voor snelle toegang een snelkoppeling op het bureaublad naar `Start.cmd` (rechtsklikken → *Snelkoppeling maken*).

Bij de eerste aanmelding controleert de tool of er benodigde onderdelen ontbreken. Zo ja, dan worden ze opgesomd en wordt eenmalig gevraagd of ze geïnstalleerd mogen worden – de installatie loopt op de achtergrond (ongeveer één tot twee minuten) en is zichtbaar in het logboek. Daarna vraagt Microsoft eenmalig om toestemming voor de machtigingen van de tool.

---

## Stap voor stap

### 1. Taal kiezen en aanmelden

De interface start in het **Engels**. Met het keuzeveld rechtsboven naast "Sign in" kunt u de taal op elk moment wijzigen, zonder herstart. De keuze wordt voor uw Windows-gebruiker opgeslagen en bij de volgende start overgenomen.

Klik rechtsboven op **"Aanmelden"**. Na een geslaagde aanmelding staat daar in het groen *"Verbonden als …"* met de tenant. **"Afmelden"** beëindigt de sessie – dat gebeurt ook automatisch bij het sluiten van het venster.

### 2. Gebruiker zoeken

Typ in het vak **"1. Gebruiker zoeken"** het begin van een naam, een e-mailadres of de UPN en druk op **Enter** (of klik op **"Zoeken"**).

- **Eén resultaat:** de gebruiker wordt direct geopend.
- **Meerdere resultaten:** onder het zoekvak klapt een lijst open – klik op de gewenste gebruiker. Met **Esc** of een klik ernaast sluit de lijst.

### 3. De MFA-status begrijpen

Rechts onder **"Geselecteerde gebruiker"** toont het **MFA-stoplicht** hoe goed het account is beveiligd:

| Stoplicht | Betekenis | Wat te doen? |
|---|---|---|
| 🟢 **Sterke MFA (phishingbestendig)** | FIDO2-sleutel, passkey of Windows Hello aanwezig | Alles in orde. |
| 🟢 **Sterke MFA** | Authenticator-app of TOTP-kaart/-app aanwezig | In orde. Voor beheerders wordt daarnaast FIDO2 aanbevolen. |
| 🟡 **Alleen zwakke MFA** | Alleen sms of oproep | Richt een betere methode in en verwijder daarna sms/oproep. |
| 🟡 **Alleen nep-MFA** | Het account is ter beveiliging geblokkeerd (zie [nep-MFA](#welke-methode-kiezen)) | Richt een echte methode in om het te kunnen gebruiken. |
| 🟡 **Alleen Temporary Access Pass** | Alleen een tijdelijke toegangscode | De gebruiker moet daarmee nu een permanente methode inrichten. |
| 🔴 **Geen MFA – alleen wachtwoord** | Geen tweede factor | Richt dringend een methode in. |

Onder het stoplicht staan concrete aanbevelingen, bijvoorbeeld *"Sms/oproep is ook geregistreerd en kan worden verwijderd"*.

Daaronder toont **"Beheerdersrollen"** of de gebruiker beheerdersrechten heeft. Met **"Tonen"** klapt de lijst open. Per rol staat ook of deze permanent actief is, via een groep is toegewezen of alleen via PIM kan worden geactiveerd.

### 4. MFA-methoden bekijken en verwijderen

Links onder **"2. Geregistreerde MFA-methoden"** staan alle methoden van de gebruiker. Een klik op een methode toont daaronder **alle details** (bijv. apparaatmodel, serienummer, aanmaakdatum).

Om een methode te verwijderen, selecteert u deze en klikt u op **"Methode verwijderen"**. Vóór het verwijderen verschijnt een bevestigingsvraag. Het wachtwoord kan niet worden verwijderd.

> [!NOTE]
> Microsoft verwerkt wijzigingen met enkele seconden vertraging. De tool wacht automatisch tot de lijst de nieuwe status toont. Klik zo nodig op **"Vernieuwen"**.

### 5. Een nieuwe methode inrichten

Kies rechts onder **"3. Methode configureren"** de gewenste methode:

![Keuze van de MFA-methode](images/en/select-method.png)

Afhankelijk van de methode verschijnen passende invoervelden (bijv. het serienummer) en een korte toelichting. Klik daarna op **"Configuratie starten"** en bevestig. Het resultaat verschijnt in het **logboek** en de methodenlijst wordt automatisch vernieuwd.

---

## Welke methode kiezen

| Methode | Wanneer gebruiken? | Wat gebeurt er? |
|---|---|---|
| **FIDO2-beveiligingssleutel** | De gebruiker krijgt een FIDO2-sleutel (bijv. YubiKey). De veiligste methode – vooral voor beheerders. | Sluit de sleutel aan en voer het serienummer in. Windows vraagt om de **pincode** van de sleutel en om deze **aan te raken**. De sleutel heet daarna `FIDO2-<serienummer>`. |
| **TOTP-kaart met vast geheim** | De gebruiker krijgt een codekaart waarvan het geheim door de fabrikant is meegeleverd. | Voer serienummer en geheim in. De kaart wordt aangemaakt, aan de gebruiker toegewezen en direct geactiveerd. |
| **Programmeerbare TOTP-kaart** | De gebruiker krijgt een codekaart die u zelf programmeert (bijv. met de app van de fabrikant). | Voer het serienummer in. De tool genereert een nieuw geheim en toont **QR-code en geheim**. Programmeer daarmee de kaart en sluit daarna de weergave met ✕. |
| **Temporary Access Pass (TAP)** | De gebruiker moet zelf de Authenticator of een passkey inrichten maar heeft nog geen methode – of is zijn methode kwijt. | Er wordt een code gegenereerd die **direct 2 uur geldig** en meermaals bruikbaar is. Deze verschijnt groot in een geel kader en kan worden gekopieerd. Een bestaande TAP wordt vervangen. |
| **Nep-MFA** | Een account dat (nog) niemand gebruikt moet worden beveiligd – bijv. een nieuw nood- of serviceaccount. | Er wordt een codemethode geregistreerd waarvan de sleutel direct wordt vernietigd. Bij aanmelden wordt MFA gevraagd die niemand kan leveren – zo is het account beschermd. |

> [!IMPORTANT]
> **TAP's, geheimen en QR-codes worden maar één keer getoond.** Ze staan niet in het logboek en kunnen later niet opnieuw worden opgevraagd. Wordt een QR-code via "QR-code opslaan …" bewaard, dan bevat het bestand het geheim – verwijder het na het programmeren.

---

## Een noodaccount aanmaken

Een **noodaccount (break-glass)** is een noodtoegang waarmee u ook in de tenant komt als normale beheerderstoegang niet werkt (bijv. door een foutief beleid voor voorwaardelijke toegang).

Klik rechtsboven op **"Noodaccount …"**:

![Dialoogvenster "Noodaccount aanmaken"](images/en/breakglass-dialog.png)

1. Selecteer het **domein** waarin het account wordt aangemaakt.
2. Bepaal of het account de rol **Global Administrator** krijgt (aanbevolen, vooraf geselecteerd).
3. Sluit de **FIDO2-sleutel** aan en voer het serienummer in.
4. Klik op **"Account aanmaken"**.

De tool doet daarna automatisch het volgende:

- account aanmaken met een **willekeurig wachtwoord** (255 tekens – het wordt nergens getoond of opgeslagen, niemand kent het)
- accountnaam wijzigen in de unieke object-ID
- rol Global Administrator toewijzen
- account direct beveiligen met **nep-MFA**
- **FIDO2-sleutel registreren** (Windows vraagt om pincode en aanraking) en daarna de nep-MFA weer verwijderen

Tot slot toont een samenvatting wat er is gedaan en wordt het nieuwe account direct weergegeven.

> [!WARNING]
> **Daarna handmatig afronden:**
> - Het account **uitsluiten van alle beleidsregels voor voorwaardelijke toegang**.
> - Een **aanmeldingsmelding** instellen, zodat elk gebruik opvalt.
> - De FIDO2-sleutel veilig bewaren (bijv. in een kluis).

Als de FIDO2-registratie mislukt of wordt geannuleerd, blijft het account beveiligd met nep-MFA. De sleutel kan later worden toegevoegd via **"3. Methode configureren → FIDO2-beveiligingssleutel"**.

---

## MFA-handleiding per e-mail

Heeft een gebruiker **geen of alleen zwakke MFA** (stoplicht rood of geel), dan verschijnt naast de MFA-status de knop **"Handleiding sturen …"**. Deze stuurt de gebruiker een e-mail met een eenvoudige stapsgewijze handleiding: aka.ms/mfasetup openen, de Microsoft Authenticator-app toevoegen, de QR-code scannen. Kan of wil de gebruiker de app niet gebruiken, dan vraagt de e-mail om contact op te nemen met de IT-afdeling – gewoon door de e-mail te beantwoorden.

![Voorbeeld van de MFA-handleiding](images/en/mfa-guide-dialog.png)

- **Eerst het voorbeeld:** de e-mail wordt precies zo getoond als hij wordt verzonden. Hij wordt pas verzonden na **"E-mail verzenden"** en een bevestiging.
- **Taal van de gebruiker:** de e-mail wordt geschreven in de voorkeurstaal van de gebruiker in Entra ID (anders in die van de tenant, anders in het Engels) en kan in het voorbeeld worden gewijzigd.
- **Afzender:** standaard uw eigen postvak. U kunt ook een gedeeld postvak opgeven (bijv. het IT-postvak) waarvoor u de machtiging *Verzenden als* hebt – antwoorden komen dan daar terecht. De laatste afzender wordt onthouden.
- **Afbeeldingen:** de schermafbeeldingen zijn als inline bijlagen (Base64) in de e-mail opgenomen – er wordt niets van internet geladen, en ze worden ook in Outlook getoond.
- **Verzenddatum in het gebruikersobject:** na het verzenden worden datum, afzender en taal opgeslagen in een open extension van de gebruiker (`com.m365mfatool.mfaGuide`). Open extensions bestaan alleen in Entra ID: ze zijn ook bij gesynchroniseerde (hybride) gebruikers schrijfbaar en worden nooit door Entra Connect / Cloud Sync overschreven – anders dan `extensionAttribute1–15`. De datum wordt onder het stoplicht en in het MFA-rapport getoond (kolom **"Handleiding verzonden"**).
- **Verzendgeschiedenis (aantal en tijdstippen):** een tweede open extension `com.m365mfatool.mfaGuideHistory` telt elke verzending (`sentCount`) en bewaart de tijdstippen van de laatste 20 verzendingen met afzender en taal (`entries`, plus `firstSentDateTime`/`lastSentDateTime`). De geschiedenis verschijnt als tooltip bij de status van de handleiding en in het tenant-MFA-rapport (kolom **"Aantal"**). hrdnr leest en schrijft dezelfde extensie.

De smartphone-schermafbeeldingen in de e-mail komen uit de Microsoft-documentatie (MicrosoftDocs/entra-docs, MIT-licentie); alle schermafbeeldingen zijn geanonimiseerd.

---

## MFA-rapport voor de tenant

Klik linksboven op **"MFA-rapport …"** om in één keer de MFA-status van **alle gebruikers van de tenant** (of van de leden van een groep, incl. geneste groepen) te controleren.

![MFA-statusrapport voor de tenant](images/en/tenant-report.png)

1. Kies het bereik: **"Alle gebruikers"** of **"Leden van een groep (incl. geneste groepen)"** (zoek de groep op het begin van de naam of op object-ID). Standaard worden alleen ingeschakelde accounts en geen gastaccounts meegenomen.
2. Klik op **"Rapport maken"**. De lijst vult zich terwijl de methoden worden gelezen (20 gebruikers per Graph-aanvraag). **"Annuleren"** stopt na het huidige blok.
3. De tegels tonen het aantal per stoplichtkleur – **klikken op een tegel filtert** de lijst. Daarnaast kunt u **zoeken** (naam, UPN, e-mail, rollen, methoden, beoordeling, afdeling) en **"Alleen beheerders"** tonen.
   De kolommen **"Laatste aanmelding"** en **"Dagen sinds"** laten zien of een account echt wordt gebruikt. Accounts zonder aanmelding in meer dan 90 dagen of die zich nooit hebben aangemeld, worden rood gemarkeerd, in een eigen tegel geteld en kunnen met **"Alleen inactief (> 90 dagen of nooit)"** worden getoond.
4. **"Excel-export …"** slaat de op dat moment getoonde items op als `.xlsx`-bestand in stoplichtkleuren, inclusief een samenvattingsblad. Excel of een extra module is niet nodig.
5. **Dubbelklikken** op een gebruiker sluit het rapport en opent de gebruiker in het hoofdvenster om te bewerken. Het rapport blijft bewaard tot u zich afmeldt.

| Stoplicht | Betekenis |
|---|---|
| 🔴 **Rood** | Geen MFA (alleen wachtwoord), **of** beheerdersrol met alleen onveilige MFA (sms/oproep, TAP of nep-MFA) |
| 🟡 **Geel** | Alleen onveilige MFA (sms/oproep, TAP of nep-MFA), **of** beheerder zonder phishingbestendige MFA (FIDO2, passkey, Windows Hello) |
| 🟢 **Groen** | Sterke MFA – voor beheerders phishingbestendig |

Als beheerdersrollen tellen actieve rollen en rollen die via PIM in aanmerking komen (gemarkeerd met "(PIM)"), en ook rollen die via groepen zijn toegewezen.

---

## Veelgestelde vragen en probleemoplossing

**Dubbelklikken op `Start.cmd` doet niets of geeft een foutmelding.**
De tool werkt alleen onder Windows. Is de map gekopieerd van internet, Teams of een ZIP-bestand, dan zijn de bestanden mogelijk geblokkeerd. Voer in PowerShell in de map eenmalig uit: `Get-ChildItem -Recurse | Unblock-File`.

**Bij aanmelden wordt opnieuw om toestemming gevraagd.**
Dat is normaal wanneer een nieuwe functie extra machtigingen nodig heeft – bijvoorbeeld bij het eerste noodaccount.

**Een nieuw aangemaakte of verwijderde methode wordt niet direct getoond.**
Microsoft heeft daar enkele seconden voor nodig. De tool wacht automatisch tot ongeveer 16 seconden; klik daarna zo nodig op **"Vernieuwen"**.

**FIDO2: "Fido credential policy …" of "niet ingeschakeld".**
FIDO2 is niet ingeschakeld in de tenant. Een beheerder moet het inschakelen in het beleid voor verificatiemethoden (zie [vereisten](#vereisten-en-machtigingen-voor-beheerders)).

**FIDO2: "De UPN is te lang".**
FIDO2 staat maximaal 64 tekens toe voor de aanmeldnaam (UPN).

**TOTP-kaart: "Een token met serienummer … is al toegewezen aan …".**
De kaart hoort al bij een andere gebruiker. Verwijder deze daar eerst.

**Foutmelding met "Authorization_RequestDenied" of "Forbidden".**
Uw account mist een beheerdersrol (zie [rollen](#vereisten-en-machtigingen-voor-beheerders)).

Elke actie staat met tijdstip in het **logboek** rechtsonder. Daarnaast wordt deze direct opgeslagen in een dagelijks logbestand in de toolmap, bijv. `Logs\2026-10-12.log` (als de map niet beschrijfbaar is: `%LOCALAPPDATA%\M365MfaTool\Logs`) – handig bij vragen.

**MFA-rapport: de kolommen voor de laatste aanmelding zijn leeg.**
Daarvoor zijn een **Entra ID P1/P2**-licentie, de machtiging `AuditLog.Read.All` en een rol die aanmeldgegevens mag lezen (bijv. **Rapportlezer**) nodig. Zonder deze wordt het rapport toch gemaakt, alleen zonder deze gegevens; het logboek vermeldt de reden.

---

## Beveiliging

- **Geen geheimen in het logboek:** TAP's, geheimen en wachtwoorden worden nooit gelogd of op schijf opgeslagen.
- **Onbekende wachtwoorden:** wachtwoorden van noodaccounts worden willekeurig gegenereerd en nooit getoond.
- **Bevestigingen:** elke wijziging moet worden bevestigd; de vragen staan standaard op "Nee".
- **Opruimen bij fouten:** mislukt het inrichten van een TOTP-kaart, dan verwijdert de tool half aangemaakte vermeldingen automatisch.

> [!CAUTION]
> Voer beheeracties alleen uit volgens uw interne goedkeurings- en beveiligingsproces.

---

## Vereisten en machtigingen voor beheerders

### Systeemvereisten

- Windows met **Windows PowerShell 5.1** (vooraf geïnstalleerd; PowerShell 7 wordt niet ondersteund omdat de interface WPF gebruikt)
- Internettoegang bij de eerste start om de PowerShell-modules te installeren (alleen voor de huidige gebruiker, geen beheerdersrechten nodig):
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Identity.SignIns` en `DSInternals.Passkeys` **1.0.6** (FIDO2)
  - `QRCodeGenerator` (QR-codes voor programmeerbare TOTP-kaarten)

  U kunt ze ook vooraf installeren met `Install-Prerequisites.ps1`.
- Voor FIDO2 moet de sleutel op de **lokale computer** zijn aangesloten (via RDP alleen met WebAuthn-omleiding).

### Graph-machtigingen (gedelegeerd)

Bij aanmelden:

| Machtiging | Waarvoor |
|---|---|
| `User.Read.All` | Gebruikers zoeken |
| `UserAuthenticationMethod.Read.All` | MFA-methoden tonen |
| `UserAuthenticationMethod.ReadWrite.All` | MFA-methoden inrichten en verwijderen |
| `Policy.ReadWrite.AuthenticationMethod` | TOTP-kaarten en nep-MFA in de tokeninventaris aanmaken/verwijderen |
| `RoleManagement.Read.Directory` | Beheerdersrollen van een gebruiker tonen |

Daarnaast bij het eerste noodaccount:

| Machtiging | Waarvoor |
|---|---|
| `User.ReadWrite.All` | Gebruikers aanmaken |
| `Domain.Read.All` | Domeinen ter selectie tonen |
| `RoleManagement.ReadWrite.Directory` | Global Administrator toewijzen |

Daarnaast voor het MFA-rapport:

| Machtiging | Waarvoor |
|---|---|
| `GroupMember.Read.All` | Een groep als bereik kiezen, beheerdersrollen die via groepen zijn toegewezen ophalen |
| `AuditLog.Read.All` | Laatste aanmelding (optioneel – zonder wordt het rapport zonder deze kolom gemaakt) |

Voor de laatste aanmelding zijn daarnaast een **Entra ID P1/P2**-licentie en een rol nodig die aanmeldgegevens mag lezen, bijv. **Rapportlezer**, **Beveiligingslezer** of **Globale lezer**. Getoond wordt de laatste geslaagde aanmelding (interactief of niet-interactief); Microsoft registreert deze sinds december 2023, oudere waarden zijn de laatste aanmeldpoging.

Daarnaast voor de MFA-handleiding:

| Machtiging | Waarvoor |
|---|---|
| `Mail.Send` | E-mail verzenden vanuit uw eigen postvak |
| `Mail.Send.Shared` | E-mail verzenden vanuit een gedeeld postvak (alleen als er een is opgegeven) |
| `User.ReadWrite.All` | Verzenddatum in het gebruikersobject opslaan |

Voor het opslaan van de verzenddatum is een rol nodig die gebruikers mag wijzigen, bijv. **Gebruikersbeheerder**.

### Benodigde Entra-rollen voor uw eigen account

| Taak | Rol |
|---|---|
| Methoden van gewone gebruikers beheren, TAP | **Authentication Administrator** |
| Methoden van beheerders beheren | **Privileged Authentication Administrator** |
| TOTP-kaarten en nep-MFA | daarnaast **Authentication Policy Administrator** |
| Noodaccount | **Global Administrator** (of Privileged Role Administrator + User Administrator) |

### Tenantinstellingen

In het **beleid voor verificatiemethoden** (Entra-beheercentrum → Beveiliging → Verificatiemethoden) moeten de gebruikte methoden zijn ingeschakeld:

- **Passkey (FIDO2)**
- **Hardware-OATH-tokens** (voor TOTP-kaarten en nep-MFA)
- **Temporary Access Pass** – maximale geldigheid minimaal 2 uur

### Opmerkingen

- Sommige functies gebruiken de **bèta-API** van Microsoft Graph (bijv. voor hardware-OATH-tokens), die kan veranderen.
- Rollen die via PIM in aanmerking komen, worden alleen getoond met Entra ID P2.
- De gekozen taal wordt opgeslagen in `%APPDATA%\M365MfaTool\settings.json`.

---

## Projectstructuur

| Bestand | Inhoud |
|---|---|
| `Start.cmd` | Starter via dubbelklik |
| `Start-M365MfaTool.ps1` | Interface, statusbeheer en gebeurtenissen |
| `UI/MainWindow.xaml` | Indeling van het hoofdvenster |
| `UI/BreakGlassDialog.xaml` | Dialoogvenster voor nieuwe noodaccounts |
| `UI/TenantReportWindow.xaml` | Venster van het MFA-rapport |
| `UI/MfaGuideDialog.xaml` | Voorbeeldvenster van de MFA-handleiding |
| `Modules/Graph.psm1` | Aanmelden, Graph-aanvragen, gebruikers, domeinen, rollen, MFA-stoplicht, methoden lezen/verwijderen |
| `Modules/Provisioning.psm1` | Inrichten van FIDO2, TOTP-kaarten, nep-MFA, TAP en noodaccounts |
| `Modules/TenantReport.psm1` | MFA-rapport: gebruikers, rollen, gebundelde methode-aanvragen, stoplichtbeoordeling, Excel-export |
| `Modules/Xlsx.psm1` | Eenvoudige Excel-writer (.xlsx zonder Excel of extra modules) |
| `Modules/MfaGuideMail.psm1` | MFA-handleiding: e-mail in de taal van de gebruiker, verzending via Graph, verzenddatum in het gebruikersobject |
| `Modules/Localization.psm1` | Meertaligheid: laadt de taalbestanden en levert de teksten |
| `Languages/*.json` | Teksten per taal (`en.json` is de referentie) |
| `Mail/Images/` | Geanonimiseerde schermafbeeldingen voor de e-mail |
| `Install-Prerequisites.ps1` | Optionele voorafgaande installatie van alle modules |
| `docs/` | Vertaalde documentatie en schermafbeeldingen |
| `Logs/` | Dagelijkse logbestanden (worden automatisch aangemaakt, niet in Git) |

---

## Een taal toevoegen

1. Kopieer `Languages/en.json` en geef het de naam van de taalcode, bijv. `sv.json` voor Zweeds.
2. Zet `"_language"` op de naam van de taal in die taal zelf (bijv. `"Svenska"`) en vertaal alle teksten. Plaatsaanduidingen zoals `{0}` moeten behouden blijven.
3. Start de tool opnieuw – de taal verschijnt automatisch in de keuzelijst. Ontbrekende teksten worden in het Engels getoond.
4. Optioneel: voeg een vertaalde documentatie toe als `docs/README.<code>.md` en neem de link op in de taalbalk bovenaan alle README-bestanden.
