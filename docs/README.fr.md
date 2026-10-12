🌐 [English](../README.md) · [Deutsch](README.de.md) · [Español](README.es.md) · **Français** · [Italiano](README.it.md) · [Português](README.pt.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md)

# M365 MFA Administration Tool

Avec cet outil, les administrateurs et le support informatique configurent **l'authentification multifacteur (MFA) pour le compte d'autres utilisateurs** – par exemple une clé FIDO2, une carte TOTP ou un code d'accès temporaire. Il montre aussi en un coup d'œil le niveau de protection d'un compte utilisateur.

> [!NOTE]
> Les captures d'écran montrent l'interface en anglais. L'interface peut être passée en français en haut à droite.

![Fenêtre principale de M365 MFA Administration Tool](images/en/main-window.png)

## Sommaire

- [En bref](#en-bref)
- [Démarrage rapide](#démarrage-rapide)
- [Guide pas à pas](#guide-pas-à-pas)
- [Choisir la bonne méthode](#choisir-la-bonne-méthode)
- [Créer un compte d'urgence](#créer-un-compte-durgence)
- [Questions fréquentes et dépannage](#questions-fréquentes-et-dépannage)
- [Sécurité](#sécurité)
- [Prérequis et autorisations pour les administrateurs](#prérequis-et-autorisations-pour-les-administrateurs)
- [Structure du projet](#structure-du-projet)
- [Ajouter une langue](#ajouter-une-langue)

---

## En bref

| | Fonction |
|---|---|
| 🔍 | **Rechercher des utilisateurs** – par nom, adresse e-mail, UPN ou ID d'objet |
| 🚦 | **Feu tricolore MFA** – indique immédiatement si un compte est bien, faiblement ou pas du tout protégé, avec une recommandation |
| 👑 | **Rôles d'administration** – indique si l'utilisateur dispose de droits administratifs |
| 📋 | **Afficher et supprimer les méthodes MFA** – toutes les méthodes enregistrées avec date et détails |
| ➕ | **Configurer des méthodes** – clé FIDO2, cartes TOTP, Temporary Access Pass et MFA fictive |
| 🆘 | **Compte d'urgence** – créer un accès d'urgence (break-glass) avec clé FIDO2 et mot de passe inconnu |
| 🌐 | **Multilingue** – anglais (par défaut), allemand, espagnol, français, italien, portugais, néerlandais et polonais |

---

## Démarrage rapide

1. Copiez le dossier complet sur votre ordinateur (les fichiers doivent rester ensemble).
2. **Double-cliquez sur `Start.cmd`.**
3. En haut à droite, choisissez **Français** comme langue et cliquez sur **« Se connecter »**. Connectez-vous avec votre propre compte administrateur.

> [!TIP]
> Pour un accès rapide, créez un raccourci sur le bureau vers `Start.cmd` (clic droit → *Créer un raccourci*).

Lors de la première connexion, l'outil vérifie si des composants nécessaires manquent. Si c'est le cas, il les liste et demande une seule fois s'il faut les installer – l'installation s'exécute en arrière-plan (une à deux minutes environ) et s'affiche dans le journal. Microsoft demande ensuite une seule fois le consentement aux autorisations de l'outil.

---

## Guide pas à pas

### 1. Choisir la langue et se connecter

L'interface démarre en **anglais**. La liste de sélection en haut à droite, à côté de « Sign in », permet de changer de langue à tout moment, sans redémarrage. Le choix est enregistré pour votre utilisateur Windows et repris au prochain démarrage.

Cliquez sur **« Se connecter »** en haut à droite. Une fois connecté, *« Connecté en tant que … »* s'affiche en vert avec le locataire. **« Se déconnecter »** met fin à la session – cela se fait aussi automatiquement à la fermeture de la fenêtre.

### 2. Rechercher un utilisateur

Dans la zone **« 1. Rechercher un utilisateur »**, saisissez le début d'un nom, d'une adresse e-mail ou de l'UPN et appuyez sur **Entrée** (ou cliquez sur **« Rechercher »**).

- **Un seul résultat :** l'utilisateur s'ouvre directement.
- **Plusieurs résultats :** une liste se déroule sous la zone de recherche – cliquez sur l'utilisateur souhaité. **Échap** ou un clic ailleurs referme la liste.

### 3. Comprendre le statut MFA

À droite, sous **« Utilisateur sélectionné »**, le **feu tricolore MFA** indique le niveau de protection du compte :

| Feu | Signification | Que faire ? |
|---|---|---|
| 🟢 **MFA forte (résistante au phishing)** | Clé FIDO2, clé d'accès ou Windows Hello présente | Tout va bien. |
| 🟢 **MFA forte** | Application Authenticator ou carte/application TOTP présente | Correct. Pour les administrateurs, FIDO2 est également recommandé. |
| 🟡 **MFA faible uniquement** | Uniquement SMS ou appel | Configurez une meilleure méthode, puis supprimez SMS/appel. |
| 🟡 **MFA fictive uniquement** | Le compte est verrouillé par sécurité (voir [MFA fictive](#choisir-la-bonne-méthode)) | Configurez une vraie méthode pour l'utiliser. |
| 🟡 **Temporary Access Pass uniquement** | Uniquement un code d'accès temporaire | L'utilisateur doit maintenant l'utiliser pour configurer une méthode permanente. |
| 🔴 **Pas de MFA – mot de passe uniquement** | Aucun second facteur | Configurez une méthode de toute urgence. |

Sous le feu figurent des recommandations concrètes, par exemple *« SMS/appel est également enregistré et peut être supprimé »*.

Plus bas, **« Rôles administratifs »** indique si l'utilisateur dispose de droits d'administration. **« Afficher »** déroule la liste. Pour chaque rôle, on voit aussi s'il est actif en permanence, attribué via un groupe ou seulement activable via PIM.

### 4. Afficher et supprimer les méthodes MFA

À gauche, sous **« 2. Méthodes MFA enregistrées »**, figurent toutes les méthodes de l'utilisateur. Un clic sur une méthode affiche en dessous **tous les détails** (p. ex. modèle d'appareil, numéro de série, date de création).

Pour supprimer une méthode, sélectionnez-la et cliquez sur **« Supprimer la méthode »**. Une confirmation est demandée avant la suppression. Le mot de passe ne peut pas être supprimé.

> [!NOTE]
> Microsoft applique les modifications avec quelques secondes de retard. L'outil attend automatiquement que la liste affiche le nouvel état. Si nécessaire, cliquez sur **« Actualiser »**.

### 5. Configurer une nouvelle méthode

À droite, sous **« 3. Configurer une méthode »**, choisissez la méthode souhaitée :

![Choix de la méthode MFA](images/en/select-method.png)

Selon la méthode, des champs adaptés (p. ex. le numéro de série) et une courte indication apparaissent. Cliquez ensuite sur **« Démarrer la configuration »** et confirmez. Le résultat apparaît dans le **journal** et la liste des méthodes est actualisée automatiquement.

---

## Choisir la bonne méthode

| Méthode | Quand l'utiliser ? | Que se passe-t-il ? |
|---|---|---|
| **Clé de sécurité FIDO2** | L'utilisateur reçoit une clé FIDO2 (p. ex. YubiKey). La méthode la plus sûre – en particulier pour les administrateurs. | Branchez la clé et saisissez le numéro de série. Windows demande le **code PIN** de la clé et de la **toucher**. La clé s'appelle ensuite `FIDO2-<numéro de série>`. |
| **Carte TOTP à secret fixe** | L'utilisateur reçoit une carte à codes dont le secret a été fourni par le fabricant. | Saisissez le numéro de série et le secret. La carte est créée, attribuée à l'utilisateur et activée immédiatement. |
| **Carte TOTP programmable** | L'utilisateur reçoit une carte à codes que l'on programme soi-même (p. ex. avec l'application du fabricant). | Saisissez le numéro de série. L'outil génère un nouveau secret et affiche le **code QR et le secret**. Programmez la carte avec, puis fermez l'affichage avec ✕. |
| **Temporary Access Pass (TAP)** | L'utilisateur doit configurer lui-même Authenticator ou une clé d'accès mais n'a encore aucune méthode – ou l'a perdue. | Un code est généré, **valable immédiatement pendant 2 heures** et utilisable plusieurs fois. Il s'affiche en grand dans un cadre jaune et peut être copié. Un TAP existant est remplacé. |
| **MFA fictive** | Un compte que personne n'utilise (encore) doit être protégé – p. ex. un nouveau compte d'urgence ou de service. | Une méthode à code est enregistrée et sa clé est détruite immédiatement. À la connexion, une MFA est exigée que personne ne peut satisfaire – le compte est ainsi protégé. |

> [!IMPORTANT]
> **Les TAP, secrets et codes QR ne sont affichés qu'une seule fois.** Ils ne figurent pas dans le journal et ne peuvent pas être récupérés ultérieurement. Si un code QR est enregistré via « Enregistrer le code QR … », le fichier contient le secret – supprimez-le après la programmation.

---

## Créer un compte d'urgence

Un **compte d'urgence (break-glass)** est un accès de secours qui permet d'accéder au locataire même lorsque les accès administrateur normaux ne fonctionnent plus (p. ex. à cause d'une stratégie d'accès conditionnel erronée).

Cliquez sur **« Compte d'urgence … »** en haut à droite :

![Boîte de dialogue « Créer un compte d'urgence »](images/en/breakglass-dialog.png)

1. Sélectionnez le **domaine** dans lequel le compte sera créé.
2. Décidez si le compte reçoit le rôle **Global Administrator** (recommandé, présélectionné).
3. Branchez la **clé FIDO2** et saisissez son numéro de série.
4. Cliquez sur **« Créer le compte »**.

L'outil effectue ensuite automatiquement :

- création du compte avec un **mot de passe aléatoire** (255 caractères – il n'est jamais affiché ni enregistré, personne ne le connaît)
- remplacement du nom du compte par l'ID d'objet unique
- attribution du rôle Global Administrator
- protection immédiate du compte par une **MFA fictive**
- **enregistrement de la clé FIDO2** (Windows demande le code PIN et un toucher), puis suppression de la MFA fictive

Pour finir, un récapitulatif indique ce qui a été fait et le nouveau compte s'affiche directement.

> [!WARNING]
> **À faire ensuite manuellement :**
> - **Exclure** le compte **de toutes les stratégies d'accès conditionnel**.
> - Configurer une **alerte de connexion** afin de repérer toute utilisation.
> - Conserver la clé FIDO2 en lieu sûr (p. ex. dans un coffre-fort).

Si l'enregistrement FIDO2 échoue ou est annulé, le compte reste protégé par la MFA fictive. La clé pourra être ajoutée plus tard via **« 3. Configurer une méthode → Clé de sécurité FIDO2 »**.

---

## Questions fréquentes et dépannage

**Un double-clic sur `Start.cmd` ne fait rien ou affiche une erreur.**
L'outil fonctionne uniquement sous Windows. Si le dossier provient d'Internet, de Teams ou d'un fichier ZIP, les fichiers peuvent être bloqués. Exécutez une fois dans PowerShell, dans le dossier : `Get-ChildItem -Recurse | Unblock-File`.

**La connexion redemande un consentement.**
C'est normal lorsqu'une nouvelle fonction nécessite des autorisations supplémentaires – par exemple pour le premier compte d'urgence.

**Une méthode nouvellement créée ou supprimée n'apparaît pas tout de suite.**
Microsoft a besoin de quelques secondes. L'outil attend automatiquement jusqu'à environ 16 secondes ; ensuite, cliquez sur **« Actualiser »** si nécessaire.

**FIDO2 : « Fido credential policy … » ou « non activé ».**
FIDO2 n'est pas activé dans le locataire. Un administrateur doit l'activer dans la stratégie des méthodes d'authentification (voir [prérequis](#prérequis-et-autorisations-pour-les-administrateurs)).

**FIDO2 : « L'UPN est trop long ».**
FIDO2 autorise au maximum 64 caractères pour le nom de connexion (UPN).

**Carte TOTP : « Un jeton avec le numéro de série … est déjà attribué à … ».**
La carte appartient déjà à un autre utilisateur. Retirez-la d'abord chez celui-ci.

**Message d'erreur avec « Authorization_RequestDenied » ou « Forbidden ».**
Il manque un rôle d'administration à votre compte (voir [rôles](#prérequis-et-autorisations-pour-les-administrateurs)).

Chaque action figure avec son heure dans le **journal** en bas à droite. Elle est aussi enregistrée immédiatement dans un fichier journal quotidien du dossier de l'outil, p. ex. `Logs\2026-10-12.log` (si le dossier n'est pas accessible en écriture : `%LOCALAPPDATA%\M365MfaTool\Logs`) – utile en cas de question.

---

## Sécurité

- **Aucun secret dans le journal :** les TAP, secrets et mots de passe ne sont jamais journalisés ni enregistrés sur le disque.
- **Mots de passe inconnus :** les mots de passe des comptes d'urgence sont générés aléatoirement et jamais affichés.
- **Confirmations :** chaque modification doit être confirmée ; les confirmations sont réglées sur « Non » par défaut.
- **Nettoyage en cas d'erreur :** si la configuration d'une carte TOTP échoue, l'outil supprime automatiquement les entrées à moitié créées.

> [!CAUTION]
> N'effectuez des actions administratives que conformément à votre processus interne d'approbation et de sécurité.

---

## Prérequis et autorisations pour les administrateurs

### Configuration requise

- Windows avec **Windows PowerShell 5.1** (préinstallé ; PowerShell 7 n'est pas pris en charge car l'interface utilise WPF)
- Accès à Internet au premier démarrage pour installer les modules PowerShell (uniquement pour l'utilisateur actuel, sans droits d'administrateur) :
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Identity.SignIns` et `DSInternals.Passkeys` **1.0.6** (FIDO2)
  - `QRCodeGenerator` (codes QR pour les cartes TOTP programmables)

  Vous pouvez aussi les installer à l'avance avec `Install-Prerequisites.ps1`.
- Pour FIDO2, la clé doit être branchée sur **l'ordinateur local** (via RDP uniquement avec la redirection WebAuthn).

### Autorisations Graph (déléguées)

À la connexion :

| Autorisation | Usage |
|---|---|
| `User.Read.All` | Rechercher des utilisateurs |
| `UserAuthenticationMethod.Read.All` | Afficher les méthodes MFA |
| `UserAuthenticationMethod.ReadWrite.All` | Configurer et supprimer des méthodes MFA |
| `Policy.ReadWrite.AuthenticationMethod` | Créer/supprimer des cartes TOTP et la MFA fictive dans l'inventaire des jetons |
| `RoleManagement.Read.Directory` | Afficher les rôles d'administration d'un utilisateur |

En plus, lors du premier compte d'urgence :

| Autorisation | Usage |
|---|---|
| `User.ReadWrite.All` | Créer des utilisateurs |
| `Domain.Read.All` | Afficher les domaines à sélectionner |
| `RoleManagement.ReadWrite.Directory` | Attribuer Global Administrator |

### Rôles Entra nécessaires pour votre propre compte

| Tâche | Rôle |
|---|---|
| Gérer les méthodes des utilisateurs standard, TAP | **Authentication Administrator** |
| Gérer les méthodes des administrateurs | **Privileged Authentication Administrator** |
| Cartes TOTP et MFA fictive | en plus **Authentication Policy Administrator** |
| Compte d'urgence | **Global Administrator** (ou Privileged Role Administrator + User Administrator) |

### Paramètres du locataire

Dans la **stratégie des méthodes d'authentification** (Centre d'administration Entra → Protection → Méthodes d'authentification), les méthodes utilisées doivent être activées :

- **Clé d'accès (FIDO2)**
- **Jetons OATH matériels** (pour les cartes TOTP et la MFA fictive)
- **Temporary Access Pass** – durée de validité maximale d'au moins 2 heures

### Remarques

- Certaines fonctions utilisent l'**API bêta** de Microsoft Graph (p. ex. pour les jetons OATH matériels), qui peut évoluer.
- Les rôles éligibles via PIM ne sont affichés qu'avec Entra ID P2.
- La langue choisie est enregistrée dans `%APPDATA%\M365MfaTool\settings.json`.

---

## Structure du projet

| Fichier | Contenu |
|---|---|
| `Start.cmd` | Lanceur par double-clic |
| `Start-M365MfaTool.ps1` | Interface, gestion de l'état et événements |
| `UI/MainWindow.xaml` | Disposition de la fenêtre principale |
| `UI/BreakGlassDialog.xaml` | Boîte de dialogue pour les nouveaux comptes d'urgence |
| `Modules/Graph.psm1` | Connexion, requêtes Graph, utilisateurs, domaines, rôles, feu tricolore MFA, lecture/suppression des méthodes |
| `Modules/Provisioning.psm1` | Configuration de FIDO2, cartes TOTP, MFA fictive, TAP et comptes d'urgence |
| `Modules/Localization.psm1` | Multilinguisme : charge les fichiers de langue et fournit les textes |
| `Languages/*.json` | Textes par langue (`en.json` est la référence) |
| `Install-Prerequisites.ps1` | Installation préalable facultative de tous les modules |
| `docs/` | Documentation traduite et captures d'écran |
| `Logs/` | Fichiers journaux quotidiens (créés automatiquement, non stockés dans Git) |

---

## Ajouter une langue

1. Copiez `Languages/en.json` et nommez-le d'après le code de langue, p. ex. `sv.json` pour le suédois.
2. Définissez `"_language"` sur le nom de la langue dans cette langue (p. ex. `"Svenska"`) et traduisez tous les textes. Les espaces réservés comme `{0}` doivent être conservés.
3. Redémarrez l'outil – la langue apparaît automatiquement dans la sélection. Les textes manquants s'affichent en anglais.
4. Facultatif : ajoutez une documentation traduite sous `docs/README.<code>.md` et ajoutez le lien dans la barre de langues en haut de tous les fichiers README.
