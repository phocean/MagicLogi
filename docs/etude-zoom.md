# Étude — zoom par ⌘ + défilement (Aperçu et autres applications)

Date : 2026-11-24. Statut : **implémenté en 1.1.0** (`[zoom]`,
`Sources/magiclogid/ScrollZoom.swift`, `Sources/MagicLogiCore/Zoom.swift`).
Résultats de la sonde au §8, de l'implémentation au §9 ; les points encore
marqués **[à vérifier]** n'ont pas été mesurés.

## 1. Verdict

**Faisable avec les seules API publiques, sans refonte**, dans le processus
`magiclogid` existant, sans nouvelle autorisation macOS (l'Accessibilité,
déjà demandée pour les remappages, suffit), sans dépendance.

- **Zoom par paliers : retenu.** Un *event tap* Core Graphics limité aux
  événements `scrollWheel` absorbe le défilement quand ⌘ est tenu au-dessus
  d'une application de la liste (Aperçu par défaut) et envoie à cette
  application ses raccourcis natifs ⌘+ / ⌘−.
- **Zoom continu : écarté.** Il faudrait synthétiser des événements de
  « magnification » (pincement) ; Core Graphics n'expose aucune API publique
  pour créer des événements de geste (types et champs non documentés).
  Contraire à la règle « API publiques et stables ».
- **Coût principal : une promesse du projet change.** README et SECURITY.md
  affirment aujourd'hui « no event tap : events of other devices never pass
  through the agent ». Avec le zoom activé, **chaque événement de défilement
  de la session** (toutes souris, trackpad, TrackPoint) passe par l'agent.
  D'où : fonction **désactivée tant que la section `[zoom]` est absente**,
  tap créé seulement si elle est activée, documentation mise à jour.
  Aucun événement clavier n'est jamais intercepté.

## 2. Ce que l'existant fournit déjà

| Besoin | Déjà présent |
|---|---|
| Envoyer un raccourci selon la disposition du clavier (AZERTY) | `Injector` : `KeyCombo`, table `UCKeyTranslate` en cache (`Sources/magiclogid/Injector.swift:135-172`) |
| Marquer nos événements synthétiques | `kCGEventSourceUserData` = « MLOG » (`Injector.swift:13`, `:131`) |
| Autorisation d'injecter | Accessibilité, vérifiée et suivie (`Agent.checkPermissions`) |
| Configuration stricte, rejet global si invalide | `Config.parse` (TOML), `magiclogictl check` |
| Boucle événementielle sans polling | un seul thread, `CFRunLoop` principal |

## 3. Le daemon TrackPoint (MagicTrackpoint 1.1.0) : ce qu'il fait réellement

Lu dans `MagicTrackpoint/src/magictrackpointd.m` :

- Deux taps actifs **au niveau HID** : `CGEventTapCreate(kCGHIDEventTap,
  kCGHeadInsertEventTap, kCGEventTapOptionDefault, …)` (l. 423), l'un pour
  les boutons « other », l'autre pour `scrollWheel`. Le tap de défilement
  n'est armé que pendant que le bouton central du TrackPoint est tenu (l. 379-388).
- Le défilement du TrackPoint est **calculé à partir des rapports HID du
  clavier** (`wheel_report`, l. 518) puis **injecté au niveau session** :
  `CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, py, px)`,
  marqué `kCGEventSourceUserData = 'MTPK'`, `CGEventPost(kCGSessionEventTap, …)`
  (l. 436-439, 524). Le sens « naturel » est déjà appliqué par le daemon.
- Le clic central est décidé par l'état du geste (rapports du clavier), pas
  par le sort des événements de défilement injectés (`mtp_gesture_*`,
  `mtp_core.h:404-432`).

Conséquences :

1. **Placement du tap de MagicLogi : `kCGAnnotatedSessionEventTap`.** Un tap
   au niveau HID ne verrait pas le défilement du TrackPoint (injecté en aval,
   au niveau session). Le niveau « annoté » est en aval des deux : il voit le
   défilement matériel (molette MX Anywhere, autres souris, trackpad) **et**
   celui injecté par MagicTrackpoint, et il fournit le processus destinataire
   de l'événement (`kCGEventTargetUnixProcessID`). L'ordre ne dépend donc pas
   de l'ordre de démarrage des deux services, seulement de l'emplacement des
   taps.
2. **Aucune boucle possible.** MagicLogi n'injecte **aucun** défilement (il
   n'en absorbe que) et son tap ne voit que `scrollWheel` ; il n'injecte que
   des touches, que les taps de MagicTrackpoint (souris et défilement) ne
   voient pas.
3. **Clic central du TrackPoint préservé** : absorber un défilement injecté ne
   change rien à la décision clic/défilement, prise avant, côté clavier.
4. **Aucune duplication dans MagicTrackpoint** : la fonction marche sur ce
   qu'il injecte, sans modification de son côté.
5. **Les modificateurs.** Ses événements sont créés avec une source `NULL`.
   Mesuré (§8) : leurs drapeaux portent bien le ⌘ tenu, comme ceux de la
   molette. Les drapeaux de l'événement suffisent donc ; l'état global
   (`CGEventSourceFlagsState`) concorde et reste un repli.

## 4. Conception proposée

### 4.1 Le tap

- `CGEventTapCreate(kCGAnnotatedSessionEventTap, kCGTailAppendEventTap,
  kCGEventTapOptionDefault, CGEventMaskBit(kCGEventScrollWheel), …)`.
  Masque : **défilement seulement**. Ni clavier, ni clics, ni mouvements.
- Créé quand `[zoom] enabled = true` **et** l'Accessibilité accordée ;
  détruit au rechargement si désactivé, et si l'Accessibilité est retirée.
  Indépendant de la connexion de la MX Anywhere (fonction pour tout
  périphérique).
- Source ajoutée au run loop principal en `commonModes`. Les échanges HID++
  bloquants de `LogiDevice.send` font tourner le run loop en mode par défaut
  (`LogiDevice.swift:151`), qui fait partie des modes communs : le tap reste
  servi pendant une attente HID++ (jusqu'à 1 s). **[à vérifier]** ; sinon,
  thread dédié au tap (seule exception justifiée au thread unique).
- `kCGEventTapDisabledByTimeout` : réactiver le tap et remettre
  l'accumulateur à zéro (comme MagicTrackpoint, l. 400-405).
  `kCGEventTapDisabledByUserInput` : ignorer (piège observé dans
  MagicTrackpoint, l. 394-399).

### 4.2 Le rappel (chemin rapide d'abord)

Pour chaque `scrollWheel` :

1. Modificateurs (drapeaux de l'événement, masqués sur ⌘ ⌥ ⌃ ⇧) **≠**
   exactement le modificateur configuré → rendre l'événement tel quel,
   remettre l'accumulateur à zéro. *C'est le cas de 99 % des événements :
   une lecture d'état, aucune allocation.*
2. Application destinataire : `pid = kCGEventTargetUnixProcessID` →
   identifiant de bundle (cache pid → bundle ID ; résolution par
   `proc_pidpath` puis `Bundle(path:)`, Foundation seule, pas d'AppKit).
   Pas dans la liste → rendre l'événement.
3. Défilement horizontal dominant (|axe 2| > |axe 1|) → rendre l'événement
   (inclinaison de molette, défilement horizontal du TrackPoint inchangés).
4. Phase d'inertie (`kCGScrollWheelEventMomentumPhase ≠ 0`) → absorber sans
   compter (sinon le document défilerait encore après le zoom).
5. Accumuler `kCGScrollWheelEventPointDeltaAxis1` (unité commune : la molette
   en lignes et le TrackPoint en pixels ont tous deux ce champ). Remise à
   zéro si le sens change ou après 300 ms sans événement. À chaque fois que
   |accumulé| ≥ `step` : un palier (au plus 3 par événement), accumulé −= step.
6. **Absorber l'événement** (`return nil`).

### 4.3 L'envoi du zoom

- Raccourcis d'Aperçu : *Présentation > Zoom avant* ⌘+ et *Zoom arrière* ⌘−.
  Mesuré (§8) : **⌘= et ⌘-** suffisent (pas besoin de ⇧), envoyés avec les
  codes de touche de la disposition active (AZERTY : `=` 0x18, `-` 0x16),
  résolus par `Injector`.
- Envoi au **processus destinataire du défilement** par
  `CGEventPostToPid(pid, …)` (API publique), pas au premier plan : le
  défilement va à la fenêtre sous le pointeur, même si son application n'est
  pas active ; un envoi global zoomerait l'application active (Safari…) à la
  place d'Aperçu. **[à vérifier]** qu'Aperçu inactif traite le raccourci ;
  sinon, règle de repli : n'agir que si l'application destinataire est au
  premier plan.
- Le ⌘ est physiquement tenu par l'utilisateur pendant l'envoi : on envoie la
  touche « + » / « − » avec le drapeau ⌘ et l'on ne touche pas à l'état réel
  du ⌘.

### 4.4 Configuration (TOML existant)

```toml
[zoom]
enabled = true                 # absent ou false : aucun tap, rien ne change
modifier = "cmd"               # cmd | alt | shift (ctrl refusé, voir §5)
step = 100                     # sensibilité : points de défilement par palier (§8)
invert = false                 # true : défilement vers le haut = zoom arrière
apps = ["com.apple.Preview"]   # bundle IDs ; défaut si absent : Aperçu seul
```

Validation stricte comme le reste (`step` 5–500, bundle IDs syntaxiquement
valides, liste non vide). `needsEventPosting` devient vrai si le zoom est
activé (l'Accessibilité est alors demandée comme pour un remappage). Ligne
d'état : `zoom=on|off|waiting-accessibility`.

Les applications qui gèrent déjà ⌘ + défilement ne sont pas touchées, puisque
seules celles de la liste le sont.

## 5. Limites et risques

| Sujet | Analyse | Mesure |
|---|---|---|
| Promesse « aucun event tap » | Le défilement de **tous** les périphériques passe par l'agent quand le zoom est activé. Seuls deltas, phase, marque et pid destinataire sont lus ; rien n'est journalisé. | Désactivé par défaut ; README, SECURITY, architecture §4 à mettre à jour ; aucun tap clavier. |
| Latence | Un tap actif ajoute un aller-retour vers l'agent pour chaque événement de défilement, partout. | Chemin rapide sans allocation ; mesure demandée en §6. |
| Agent bloqué | Si le run loop ne répond pas, macOS retarde puis **désactive** le tap (timeout) : défilement saccadé avant la désactivation. | Vérifier §4.1 ; thread dédié si besoin ; réactivation sur timeout. |
| Arrêt ou plantage | Le tap appartient au processus : il disparaît avec lui, le défilement redevient natif immédiatement. Aucun état laissé dans le système. | À tester (§6). |
| Trackpad, Magic Mouse | ⌘ + défilement à deux doigts zoomera aussi dans Aperçu (exigence « indépendant du matériel »). Le pincement reste natif. | Documenter ; option d'exclusion des événements à phase si gênant. |
| Sens du zoom | Mesuré avec défilement naturel activé et molette non inversée : delta vertical positif = zoom avant, ce que l'utilisateur juge correct (molette vers le haut = agrandir). Le signe suit le réglage « défilement naturel » et `[scroll] invert`. | Compenser le défilement naturel désactivé **[à vérifier]** ; `invert` pour corriger. |
| ⌃ + défilement | C'est le zoom d'accessibilité de macOS (écran entier) quand il est activé. | `ctrl` refusé comme modificateur. |
| Saisie sécurisée | Pendant une demande de mot de passe, macOS peut refuser l'injection de touches **[à vérifier]**. | Le défilement est alors rendu tel quel (jamais absorbé sans effet). |
| Logi Plugin Service | Sans rapport : le tap est au niveau des événements, pas du HID++. | — |
| Rafales | Molette haute résolution ou TrackPoint : nombreux petits deltas. | Accumulateur, 3 paliers max par événement. |

## 6. Plan de tests

**Automatisés** (`MagicLogiCore`, sans IOKit) : accumulateur (seuils, sens,
remise à zéro, plafond, inertie, horizontal dominant), analyse et rejets de
`[zoom]`, défaut Aperçu, `ctrl` refusé.

**Sur le matériel** (critères de la demande) :

| # | Scénario | Attendu |
|---|---|---|
| 1 | PDF dans Aperçu, ⌘ + molette MX Anywhere haut/bas | zoom avant/arrière, un palier par cran environ |
| 2 | Image dans Aperçu, idem | idem |
| 3 | TrackPoint : bouton central tenu + ⌘ + mouvement vertical | zoom progressif, sans rafale |
| 4 | TrackPoint : clic central sans mouvement, ⌘ tenu ou non | clic central inchangé |
| 5 | Défilement sans ⌘ partout (Aperçu compris) | natif |
| 6 | ⌘ + défilement horizontal (inclinaison, TrackPoint) dans Aperçu | natif |
| 7 | ⌘ + défilement dans Safari, Finder, Xcode | comportement natif de l'application |
| 8 | Aperçu en arrière-plan sous le pointeur, autre app active | zoom d'Aperçu seulement, rien dans l'app active |
| 9 | Latence perçue (défilement continu 30 s, souris et TrackPoint) | aucune différence perceptible avec/sans |
| 10 | CPU au repos 60 s, puis pendant 30 s de défilement | 0 % au repos ; défilement : mesuré et consigné |
| 11 | `magiclogictl stop`, puis `kill -9` | défilement natif immédiat, ⌘ + défilement natif dans Aperçu |
| 12 | Accessibilité retirée en marche | tap détruit, défilement natif |
| 13 | MagicTrackpoint arrêté puis relancé, zoom en marche | aucun effet sur l'un ou l'autre |
| 14 | Disposition AZERTY et QWERTY | zoom avant et arrière corrects |

## 7. Plan d'implémentation (≈ 250 lignes, aucune dépendance)

0. **Sonde (lecture seule, avant tout code définitif)** : sous-commande de
   diagnostic `magiclogid scroll-probe [s]`, lancée comme `events` en tâche
   ponctuelle, avec un tap **en écoute seule** sur `scrollWheel` au niveau
   annoté ; elle affiche par événement : deltas, unité, continu, phases,
   marque, pid destinataire, modificateurs selon l'événement et selon
   `CGEventSourceFlagsState`. Elle tranche les **[à vérifier]** des §3 et
   §4 (drapeaux des événements de MagicTrackpoint, pid présent, signe des
   deltas). Puis un essai manuel de `CGEventPostToPid` vers Aperçu inactif et
   de ⌘+ sur AZERTY.
1. `MagicLogiCore/Zoom.swift` : `ZoomConfig` + `ZoomAccumulator` (logique
   pure) et leurs tests ; section `[zoom]` dans `Config.parse`.
2. `magiclogid/ScrollZoom.swift` : tap, cache pid → bundle, envoi par
   `Injector`.
3. `Agent` : création/destruction au chargement de la configuration et au
   changement d'autorisation ; ligne d'état ; journal sans aucun contenu
   d'événement.
4. Documentation : README (deux langues), SECURITY.md (« no event tap »
   devient « no event tap unless `[zoom]` is enabled, scroll events only »),
   architecture (§4 surface d'attaque, §5 limites, §6 mesures), exemple de
   configuration commenté.
5. Tests du §6, puis version 1.1.0.

Rien n'est à changer dans MagicTrackpoint.

## 8. Résultats de la sonde (2026-11-24)

`magiclogictl scroll-probe 300 --try-zoom` : tap **en écoute seule** au niveau
session annoté ; ⌘ + défilement au-dessus d'Aperçu y envoie ⌘= / ⌘- par
`CGEventPostToPid` (au plus un toutes les 150 ms). macOS 27.3, MX Anywhere 2S,
clavier Lenovo avec MagicTrackpoint 1.1.0, disposition AZERTY, défilement
naturel activé. Capture : 484 événements de défilement.

| Question | Résultat |
|---|---|
| Le tap annoté voit-il la molette **et** le TrackPoint ? | Oui : 96 événements matériels (source 0, sans marque, `cont 0`) et 388 de MagicTrackpoint (source `magictrackpointd`, marque `MTPK`, `cont 1`). |
| Processus destinataire disponible ? | Oui, pour les deux : `com.apple.Preview`, `com.apple.finder`. |
| ⌘ présent dans les événements du TrackPoint ? | Oui : 453 événements avec ⌘ tenu, drapeaux de l'événement = état réel dans 100 % des cas (484/484). |
| Phases (trackpad, inertie) ? | Aucune : `phase 0/0` partout (ni molette ni TrackPoint n'en produisent). |
| Grandeurs | Molette : salves de ~6 événements par geste, points 1 → 55 (accélération macOS), ~150-200 points par salve. TrackPoint : 10 points par événement (`fixed` ±1,0), ~30 événements/s. |
| ⌘= / ⌘- par `CGEventPostToPid` à Aperçu au premier plan | **Zoom avant et arrière** obtenus avec la molette et avec le TrackPoint + bouton central (utilisateur). |
| Sens | Molette vers le haut = agrandir (utilisateur), avec la règle « delta > 0 = zoom avant ». |
| Aperçu en arrière-plan, Finder actif | **Non concluant** : les 49 événements de cet essai avaient le Finder pour destinataire (pointeur sur le bureau ou une fenêtre du Finder ?), donc rien n'a été envoyé à Aperçu. À refaire avec l'implémentation (test 8). |
| Débordements du tap | Aucun « tap disabled » pendant 300 s. |

Conséquences pour la conception :

- Placement au niveau annoté **confirmé** ; aucune modification de
  MagicTrackpoint nécessaire.
- Les **drapeaux de l'événement** suffisent pour le modificateur.
- **⌘= / ⌘-** résolus selon la disposition : confirmé sur AZERTY.
- `step` par défaut ≈ 100 points : environ un palier par cran de molette lent,
  trois au plus par salve rapide ; environ trois paliers par seconde au
  TrackPoint. À régler pendant les tests.
- Pendant l'essai, le document défilait aussi (tap en écoute seule) : la
  version définitive **absorbe** l'événement.

Restent **[à vérifier]** avec l'implémentation : Aperçu inactif sous le
pointeur (test 8), sens avec défilement naturel désactivé, service du tap
pendant une attente HID++ de l'agent (§4.1), latence et CPU (tests 9-10).

## 9. Implémentation (1.1.0) et écarts avec l'étude

- **Raccourcis envoyés par position physique**, pas par caractère. Mesuré :
  ⌘- (caractère, touche 0x16 en AZERTY) dézoomait un PDF mais **jamais une
  image**. Le menu *Présentation* d'Aperçu, lu par l'API d'accessibilité,
  donne *Réduire* = **⌘)** et *Agrandir* = ⌘+ : macOS localise les
  équivalents clavier des menus selon la **position** des touches (le « ) »
  AZERTY est à la place du « - » QWERTY). Un PDF dézoomait quand même parce
  que PDFKit traite ⌘- lui-même. L'agent envoie donc les touches ANSI `=`
  (0x18) et `-` (0x1B) avec ⌘ : correct sur QWERTY comme sur AZERTY.
  Vérifié : PNG et PDF, zoom avant et arrière, molette et TrackPoint.
- **Modificateur lu dans les drapeaux de l'événement** (la sonde a montré
  qu'ils portent ⌘ pour MagicTrackpoint aussi).
- `step` par défaut **120** points ; jugé correct à l'essai.
- Configuration : les listes TOML de chaînes (`apps = [...]`) ont été ajoutées
  au sous-ensemble TOML, sur une seule ligne.
- Mesuré au repos, zoom activé : voir architecture §6.

Toujours **[à vérifier]** : Aperçu en arrière-plan sous le pointeur (test 8),
sens avec défilement naturel désactivé, retrait de l'Accessibilité en marche
(test 12), arrêt et relance de MagicTrackpoint (test 13), latence sur la durée.
