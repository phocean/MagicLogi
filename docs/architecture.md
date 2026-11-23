# magiclogi — architecture, permissions, limites, tests

Licence GPL-3.0-or-later. Swift, aucune dépendance externe. ~2 200 lignes de
Swift dont ~900 de logique pure testée.

## 1. Vue d'ensemble

```text
launchd (LaunchAgent utilisateur, session Aqua, KeepAlive sur crash, Throttle 5 s)
  └─ magiclogid run              un processus, un thread, une boucle d'exécution
       ├─ IOHIDManager           046D:B01A uniquement, ouverture NON exclusive
       │    ├─ apparition        → ouverture → application de la config (~1 s)
       │    ├─ disparition       → relâche tout ce qui a été synthétisé
       │    └─ rapport 0x11      → réponses HID++ / notifications
       ├─ notifications HID++    0x1B04 fn0 boutons détournés, fn1 mouvement (gestes)
       │                         0x1D4B reconnexion → réapplication, 0x1000 batterie
       ├─ CGEventPost            actions synthétisées (Accessibilité)
       ├─ IORegisterForSystemPower  veille : relâche tout ; réveil : réapplication +2 s
       └─ signaux                SIGHUP rechargement, SIGTERM/SIGINT arrêt propre
magiclogictl (bash)  → launchctl, fichier d'état, tâches ponctuelles diag/events/reset
~/.config/magiclogi/config.toml    ~/.local/state/magiclogi/status
```

Trois couches, séparées comme demandé :

| Couche | Fichiers | Rôle |
|---|---|---|
| Cycle de vie | `Agent.swift` | découverte, ouverture, reconnexion, veille, signaux, permissions |
| HID++ / matériel | `LogiDevice.swift`, `HIDPP.swift`, `Payloads.swift` | requêtes synchrones, décodage validé, DPI, molette, détournement |
| Traduction d'événements | `Injector.swift`, `Actions.swift`, `Config.swift` (`GestureTracker`, `DivertedButtonTracker`) | uniquement pour les boutons remappés |

`MagicLogiCore` (logique pure, sans IOKit ni CoreGraphics) est couvert par
`swift test`. `magiclogid` regroupe agent et outils de diagnostic dans un seul
binaire : les autorisations TCC, liées à la signature, valent pour les deux.

## 2. Principe : régler la souris, ne rien intercepter

| Besoin | Mécanisme | Conséquence |
|---|---|---|
| DPI | `0x2201` setSensorDpi | rien à faire à l'exécution |
| Sens de la molette | `0x2121` bit invert | le trackpad n'est pas touché ; aucun événement réécrit |
| Bouton remappé | `0x1B04` détournement **temporaire** → notification HID++ → `CGEventPost` | la souris n'émet plus l'événement natif : ni doublon, ni filtrage, ni event tap |
| Geste | détournement + `rawXY` : le mouvement arrive en HID++ tant que le bouton est tenu, le pointeur ne bouge pas | la direction est connue sans toucher au flux du pointeur |
| Bouton natif | rien | l'agent n'intervient pas |

**Aucun event tap, aucune saisie exclusive.** Le clavier TrackPoint, le
trackpad et l'event tap de MagicTrackpoint ne voient aucune différence ; les
événements synthétisés portent `kCGEventSourceUserData = 0x4D4C4F47` (« MLOG »).

L'application est **idempotente** : chaque valeur est lue puis écrite seulement
si elle diffère (mesuré : une réapplication sans changement n'écrit rien). Les
six contrôles gérés (`0x52 0x53 0x56 0x5B 0x5D 0xD7`) sont toujours forcés à
l'état voulu, ce qui efface aussi un détournement laissé par un plantage.

## 3. Choix vérifiés en cours de route

| Constat (sur ce Mac) | Décision |
|---|---|
| Le détournement survit à la mort du processus (`kill -9` → `flags=0x01`) | ne détourner que les boutons remappés ; annulation au SIGTERM ; relance `launchd` mesurée < 1 s ; réimposition au démarrage |
| Éteindre/rallumer la souris efface DPI, inversion et détournements ; le périphérique disparaît puis réapparaît | réapplication à chaque apparition (mesuré ~1,1 s) et sur `0x1D4B` |
| `CGPreflightPostEventAccess()` garde sa première réponse toute la vie du processus | test `AXIsProcessTrusted()` (lu en direct) ; minuterie de 5 s **uniquement** tant qu'une autorisation manque |
| Codes de touches ANSI : ⌘[ ne fait rien en AZERTY, `cmd+a` aurait envoyé ⌘Q | caractères résolus dans la disposition active (`UCKeyTranslate`) ; back/forward = boutons 4/5 |
| Raccourcis système personnalisés (Mission Control sur ⇧⌘↑ ici) | actions nommées = raccourci réel lu dans `com.apple.symbolichotkeys` à chaque appui |
| Raccourcis système ignorés si seul le drapeau du modificateur est posé | touches de modification réellement enfoncées/relâchées autour de la touche |
| Callback « valeur » sur la page FF43 : réponses perdues | callback de rapports ; rapports non HID++ écartés au premier octet sans copie |
| Pas de notification HID++ fiable pour le clic de molette ? Faux : `0x2121` fn1 (ratchet) est émis | journalisé seulement, la bascule reste mécanique |

## 4. Permissions et surface d'attaque

| Permission | Nécessaire | Pourquoi | Si absente |
|---|---|---|---|
| Surveillance de l'entrée | toujours | la souris BLE est un seul `IOHIDDevice` d'usage principal **clavier** ; macOS refuse `IOHIDDeviceOpen` (`kIOReturnNotPermitted`, vérifié) | rien n'est modifié ; l'agent attend l'autorisation |
| Accessibilité | si un bouton a une action synthétisée | `CGEventPost` | les boutons concernés restent **natifs** (jamais détournés sans pouvoir agir) ; si retirée en marche, retour au natif au premier appui |
| Administrateur, SIP, extension noyau/système, Bluetooth, réseau | jamais | — | — |

Ce que le processus reçoit : tous les rapports d'entrée **de la souris seule**
(mouvement, boutons, et son rapport clavier `0x01` que la MX Anywhere 2S
n'utilise pas). Les rapports autres que `0x11` sont rejetés avant toute copie ;
rien n'est stocké ni journalisé. Le clavier TrackPoint n'est jamais ouvert.

Entrées non fiables et leur traitement :

| Source | Traitement |
|---|---|
| Rapports HID++ (périphérique, BLE) | longueur et ID de rapport vérifiés ; réponses appariées par fonction **et** ID logiciel `0x0C` ; chaque champ lu avec bornes (`u16(at:)`), listes plafonnées (DPI 2 000 valeurs, 32 contrôles), sommes de gestes bornées ; erreurs HID++ et délais gérés sans plantage |
| `config.toml` | sous-ensemble TOML strict ; clés, tables et valeurs inconnues refusées avec numéro de ligne ; plages validées |
| `com.apple.symbolichotkeys` | entrée mal formée → raccourci par défaut ; code de touche borné 0–127 ; raccourci désactivé → rien n'est envoyé |
| Arguments de `magiclogictl` | échappés en XML pour le plist ponctuel ; seules `diag`, `events`, `reset` sont lancées ainsi |

Pas de socket, pas de port Mach publié, pas de commande à distance : le seul
canal de contrôle est `launchd` (signaux) et le fichier de configuration de
l'utilisateur. Fichier d'état : `~/.local/state/magiclogi/status`, répertoire
`0700`, ne contient que connexion, batterie, DPI et boutons détournés.

**Signature** : runtime renforcé, identifiant `com.jcbaptiste.magiclogi`,
`Info.plist` intégré (`__TEXT,__info_plist`). Avec un certificat Developer ID ou
Apple Development, l'exigence désignée ne dépend que de l'identifiant et de
l'équipe : les autorisations TCC survivent aux recompilations. Aucune
notarisation nécessaire pour une installation locale compilée sur place.

### Revue de sécurité (2026-11-23, agent indépendant)

Aucun constat critique ou élevé. Corrigés et revérifiés sur le matériel :

| Constat | Correction |
|---|---|
| M1 `events --divert` interrompu laissait les boutons muets ; il défaisait aussi les détournements de l'agent | état d'origine lu puis restauré exactement, y compris sur SIGINT/SIGTERM (vérifié : 8 contrôles restaurés après `bootout`) ; refusé tant que l'agent tourne |
| F1 appui traité pendant l'arrêt → touche restée enfoncée ; relâché recalculé (disposition ou raccourci changé entre-temps) | notifications ignorées pendant l'arrêt, `releaseHeld()` aussi juste avant `exit` ; l'action concrète (codes de touche) est figée à l'appui et relâchée à l'identique |
| F2 à l'arrêt, seuls les boutons « connus détournés » étaient rendus | tous les contrôles gérés sont rendus, échecs journalisés |
| F3 `diag` lancé pendant l'agent pouvait lui voler une réponse HID++ | ID logiciel distinct pour les outils (`0x0E`), l'agent garde `0x0C` (vérifié : `diag` en parallèle sans effet sur l'agent) |
| Aide citant un script supprimé ; chemin personnel journalisé en clair | corrigés |

**Risque accepté (M2)** : l'exigence désignée d'une signature Developer ID ne
dépend que de l'identifiant et de l'équipe. Un programme malveillant déjà
présent sous ce compte **et** capable d'utiliser la clé de signature du
trousseau pourrait signer son propre binaire `com.jcbaptiste.magiclogi`, le
déposer à `~/.local/bin/magiclogid` et hériter des autorisations (Surveillance
de l'entrée = lecture de tous les claviers). Contre-mesures : n'accorder à
`codesign` l'accès à la clé que sur confirmation (pas « Toujours autoriser ») ;
ou installer en ad hoc (`MAGICLOGI_SIGN_IDENTITY=- make install`), ce qui lie
les autorisations à ce binaire exact au prix de les réaccorder à chaque
réinstallation. Le comportement par défaut reste celui de MagicTrackpoint.

## 5. Limites vérifiées

- Un seul modèle (`046D:B01A`) et une seule souris à la fois.
- Pas de détournement **persistant** ni de remappage vers une touche dans la
  souris (fonctions absentes) : les remappages exigent l'agent en marche.
- Après un plantage, un bouton remappé est muet jusqu'à la relance (< 1 s
  mesuré ; au-delà de plusieurs plantages rapprochés, `launchd` espace les
  relances de 5 s).
- Bouton gestuel : le clic est envoyé **au relâché** ; pas de maintien ni de
  glisser avec ce bouton. Gestes enchaînables sans relâcher (le 2e et les
  suivants à 2,25 fois le seuil, réglé à l'essai : 3 fois trop long, 1,5 fois
  déclenche des rafales).
- Vitesse/lissage du défilement : non gérés (il faudrait détourner la molette,
  qui deviendrait muette si l'agent s'arrêtait). Le réglage macOS s'applique.
- L'inversion matérielle ne concerne que la molette verticale ; l'inclinaison
  suit le réglage « défilement naturel » de macOS.
- Mode « haute résolution » de la molette non utilisé : macOS n'en connaît pas
  le multiplicateur et défilerait 8 fois trop vite.
- La batterie n'est connue que par paliers (50 %, 20 %…) : c'est ce que
  renvoie `0x1000` sur ce modèle.
- Le DPI et l'inversion restent dans la souris après arrêt de l'agent jusqu'au
  prochain cycle d'alimentation ou `magiclogictl reset`.
- **Logiciel Logitech en concurrence** (vérifié le 2026-11-23). *Logi Plugin
  Service* (`/Applications/Utilities/LogiPluginService.app`, installé par
  Logi Options+ et laissé en place par sa désinstallation) démarre à
  l'ouverture de session et se connecte à la souris en Bluetooth (GATT,
  `LogiPluginServiceExt` dans les journaux de `bluetoothd`) à chaque
  allumage de l'écran. Dès lors la souris lui envoie les événements des
  boutons détournés : ils deviennent muets (ni action ni clic natif) alors
  que leurs drapeaux se relisent « détourné ». Un nouveau détournement par
  l'agent rend la main jusqu'à la connexion suivante. Preuve : relance
  volontaire du service, connexion à 13:05:41, boutons muets aussitôt ;
  service arrêté et désinstallé, plus aucune connexion ni panne. C'était la
  cause des pannes « au retour devant le Mac » de 1.0.0 et 1.0.1 (la
  réécriture des détournements à +5 s ajoutée en 1.0.1 ne l'évitait que
  lorsqu'elle passait après cette connexion ; elle reste en filet de
  sécurité). Il n'est pas possible de le neutraliser sans droits
  administrateur ni sans toucher à un autre logiciel : l'agent **le
  signale** (journal, `magiclogictl status` ligne `conflicts=`, installeur).
  Il teste seulement l'existence de quatre chemins fixes (Logi Plugin
  Service, Logi Options+, Logi Options, G HUB ; seul le premier a été testé)
  au démarrage, à la connexion et au réveil ; aucune liste de processus n'est
  lue. Remède : désinstaller ce logiciel (README, « Si un bouton ne répond
  plus »).
- Une **demande de mot de passe** à l'écran (saisie sécurisée,
  `kCGSSessionSecureInputPID`) fait refuser par macOS l'écriture vers la
  souris (`IOHIDDeviceSetReport`, `0xE00002E2`), dont le périphérique a
  l'usage « clavier » : pendant ce temps la configuration ne peut pas être
  appliquée (journal : erreurs d'écriture). Une fois la fenêtre fermée,
  `magiclogictl restart` l'applique (vérifié).

## 6. Tests et mesures

### Automatisés (`make test`)

33 tests XCTest : trames HID++ (encodage, réponses, erreurs, rejets), décodage
des charges **réellement lues sur la souris** (liste DPI, contrôles,
rapports), batterie, molette, mouvement, reconnaissance de gestes, TOML
(valides et 15 cas d'erreur), configuration stricte, actions, raccourcis système
(entrées réelles de ce Mac), suivi des boutons, validité de l'exemple fourni, détection des logiciels
Logitech en concurrence (chemins fixes seulement).
Plus : `bash -n` des scripts, `plutil -lint` du LaunchAgent.

### Observés sur le matériel (2026-11-22/23, macOS 27.3, firmware MPM13.00 B0003)

| Scénario | Résultat |
|---|---|
| Connexion initiale, application | DPI 1200, inversion, 3 boutons détournés en ~1,1 s |
| Boutons latéraux remappés (boutons 4/5) | OK (utilisateur) |
| Raccourci clavier en AZERTY (`keys:cmd+m`) | ⌘M reçu (fenêtre réduite) |
| Mission Control via raccourci personnalisé | OK (utilisateur) |
| Bouton gestuel : clic = clic central, gauche/droite/haut/bas | OK (utilisateur) |
| Défilement horizontal (inclinaison native) | OK (utilisateur) |
| Inversion molette souris, trackpad inchangé | OK (utilisateur) |
| Extinction/rallumage de la souris | tout réappliqué (~1 s après reconnexion), confirmé par l'utilisateur |
| `kill -9` de l'agent | relance par `launchd` < 1 s, état réimposé |
| Arrêt propre | tous les contrôles `flags=0x00` relus |
| Clavier TrackPoint utilisé en même temps | aucune anomalie (utilisateur) |
| Accessibilité accordée pendant l'exécution | détectée (après correctif `AXIsProcessTrusted`) |
| CPU au repos (60 s) | 0,0 %, 0,05 s de CPU, 1 réveil, 5 Mo (empreinte), 14,9 Mo RSS |
| Aller-retour HID++ | 20 à 450 ms (radio BLE en veille au premier échange) |
| Reconnexion après veille profonde de la souris (1.0.0) | boutons détournés muets, réparé par `restart` ; cause : Logi Plugin Service (voir les limites) |
| 1.0.1 : extinction/rallumage de la souris | réécriture des détournements à +5 s, gestes OK (utilisateur) |
| 1.0.1 : veille d'une minute puis réveil du Mac | réécriture à +7 s, gestes OK (utilisateur) |
| 1.0.1 : retour après une longue absence | boutons muets ; Logi Plugin Service connecté à l'allumage de l'écran (journaux `bluetoothd`) |
| Relance volontaire de Logi Plugin Service | connexion à la souris, boutons muets aussitôt (utilisateur) ; `restart` les rend |
| Logi Plugin Service désinstallé | plus aucune connexion de sa part, boutons détournés |
| 1.0.2 : détection des logiciels en concurrence | `conflicts=none` une fois désinstallé ; tests unitaires pour le cas présent |

### Restant à valider par l'utilisateur

- Reconnexion après une longue veille de la souris (plusieurs heures), Logi
  Plugin Service désinstallé.
- Redémarrage du Mac (démarrage à l'ouverture de session).
- Latence perçue sur une longue durée ; stabilité mémoire sur plusieurs jours
  (`ps -o rss= -p $(pgrep -f 'magiclogid run')`).
- CPU pendant un mouvement continu de la souris (chaque rapport de mouvement
  réveille brièvement le processus, écarté au premier octet).
