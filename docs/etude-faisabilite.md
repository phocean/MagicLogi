# Étude de faisabilité — MX Anywhere 2S en Bluetooth direct sur macOS

Date : 2026-11-22/23. Mac : MacBook Pro Apple Silicon, macOS 27.3 (26C5035r).
Souris : Logitech MX Anywhere 2S, `046D:B01A`, Bluetooth Low Energy, firmware
`MPM13.00 build 0003` (bootloader `BOT57.00`). Logi Options+ n'est pas installé
(seul `LogiPluginService` subsiste, il n'ouvre pas la souris).

Légende des niveaux de preuve :

- **D** documenté (spécification HID++ générique, telle qu'appliquée par Solaar et OpenLogi) ;
- **I** démontré par une implémentation ou un relevé existant pour ce modèle
  (dump Solaar `docs/devices/Wireless Mobile Mouse MX Anywhere 2S B01A.txt`,
  même firmware) ;
- **V** **vérifié sur le matériel de ce Mac** par `magiclogid diag` / `events`.

## 1. Ce que macOS expose

Descripteur HID lu dans l'IORegistry (lecture seule) — **V** :

| Rapport | Sens | Contenu |
|---|---|---|
| `0x01` | entrée | clavier (modificateurs + 6 touches) — jamais utilisé par la souris dans nos essais |
| `0x02` | entrée | souris : 16 boutons, X/Y 12 bits, molette 8 bits, AC Pan 8 bits |
| `0x11` | entrée + sortie | collection vendeur `FF43:0202`, 19 octets : **HID++ 2.0 long** |

Il n'y a pas de rapport court `0x10` : tout passe en rapport long. En Bluetooth,
la souris est **un seul** `IOHIDDevice` dont l'usage principal est
`0001:0006` (clavier).

## 2. Accès macOS — vérifié

| Point | Résultat | Preuve |
|---|---|---|
| Ouvrir le périphérique sans Surveillance de l'entrée | **refusé** `kIOReturnNotPermitted` | **V** (premier essai) |
| Ouvrir avec Surveillance de l'entrée accordée à `magiclogid` | OK, **sans saisie exclusive** (`kIOHIDOptionsTypeNone`) | **V** |
| Envoi HID++ | `IOHIDDeviceSetReport(kIOHIDReportTypeOutput, 0x11, 20 octets)` | **V** ; même méthode dans OpenLogi **I** |
| Index de périphérique | `0xFF` | **V** (réponses reçues) ; Solaar, logiops **I** |
| Version HID++ | **4.5** | **V** |
| Latence aller-retour | 20 à 450 ms (BLE, la souris s'endort) | **V** |
| Filtrer les seuls rapports `0x11` (callback de valeur sur la page FF43) | **inutilisable** : 1re réponse illisible, 2e réponse identique perdue (macOS ne notifie qu'un *changement* de valeur) | **V** |
| Pas de SIP à désactiver, pas d'extension noyau/système, pas de root | confirmé | **V** |

Conséquence : le rappel de rapports reçoit aussi les rapports de mouvement de
la souris (jamais ceux du clavier TrackPoint, qui est un autre périphérique).
Ils sont écartés au premier octet, sans copie. Au repos : aucun rapport, aucun
réveil.

## 3. Fonctions HID++ présentes (23 + ROOT) — V

Fonctions utiles : `0x0001` FEATURE_SET, `0x0003` FW, `0x0005` NAME,
`0x1D4B` WIRELESS_DEVICE_STATUS, `0x0020` CONFIG_CHANGE, `0x1000`
BATTERY_STATUS, `0x1814` CHANGE_HOST (3 canaux), `0x1B04` REPROG_CONTROLS_V4
v3, `0x2201` ADJUSTABLE_DPI v1, `0x2100` VERTICAL_SCROLLING, `0x2121`
HIRES_WHEEL. Les autres (`0x18xx`, `0x1DF3`, `0x1E00`, `0x1EB0`, `0x9001`)
sont cachées/ingénierie : **non utilisées**.

**Absentes** (donc rien de ce qui suit n'est possible matériellement) :
`0x1C00` (remappage persistant vers une touche), `0x8100` (profils embarqués),
`0x2110` SmartShift, `0x2120`, `0x2150`, `0x1004`, `0x1001`.

## 4. Matrice de faisabilité

| Fonction | Protocole / API | Support confirmé | Permissions | Difficulté |
|---|---|---|---|---|
| Détection, connexion | IOHIDManager, `046D:B01A`, transport BLE | **V** | Surveillance de l'entrée | faible |
| Reconnexion, réveil | rappel d'apparition IOHIDManager + notification HID++ `0x1D4B` | **V** : extinction/rallumage = disparition puis réapparition du périphérique ; la souris **oublie** DPI, inversion et détournements → réapplication nécessaire (faite en ~1 s). Veille du Mac : à valider | — | faible |
| **DPI matériel** | `0x2201` fn1 liste, fn2 lecture, fn3 écriture | **V** : 200…4000 par pas de 50 (77 valeurs), actuel 1000, défaut 1000 | Surveillance de l'entrée | faible |
| Boutons latéraux natifs | rapport `0x02` | **V** : arrière = bouton 4, avant = bouton 5 | aucune (rien à faire) | nulle |
| Bouton central dédié (derrière la molette) natif | rapport `0x02` | **V** : bouton 3 (CID `0x0052`) | aucune | nulle |
| Remappage boutons (central, arrière, avant, inclinaisons) | `0x1B04` détournement temporaire → notifications HID++ → action synthétisée `CGEventPost` | **V** : 5 contrôles détournables, appui/relâché et accords reçus, aucun événement natif émis pendant le détournement | Surveillance de l'entrée + **Accessibilité** (seulement si un bouton est remappé) | moyenne |
| Détournement persistant | `0x1B04` bit persist | **impossible** : aucun contrôle `persistentlyDivertable` **V** | — | — |
| Remappage vers une touche dans le firmware | `0x1C00` | **impossible** : fonction absente **V** | — | — |
| Clic de la molette | mécanique (cranté ↔ libre) | **V** : aucun bouton HID ; notification HID++ `0x2121` fn1 (ratchet) à chaque bascule ; état lisible fn3 = 1 (cranté) | — | hors périmètre |
| Défilement horizontal (inclinaison) | AC Pan natif | **V** : ±1 répété ~10/s tant que l'inclinaison est tenue ; macOS le convertit seul | aucune | nulle |
| Sens du défilement vertical, **par la souris seule** | `0x2121` bit invert (fn2 setWheelMode) | capacité `0x0C` = invert + ratchet **V** ; effet vérifié : molette inversée, trackpad inchangé **V** | Surveillance de l'entrée | faible |
| Vitesse de défilement | `0x2121` hi-res (×8) ou détournement de la molette | hi-res : macOS ignore le multiplicateur → défilement ×8 (**D**, non retenu) ; détournement = réimplémenter le défilement (**non retenu en V1**) | — | élevée |
| Batterie | `0x1000` fn0 + événement fn0 | **V** : 50 %, « discharging » (paliers grossiers) | Surveillance de l'entrée | faible |
| Raccourcis clavier, Mission Control, espaces | `CGEventPost` ; raccourci réel lu dans `com.apple.symbolichotkeys` ; caractères résolus dans la disposition clavier active | **V** (après deux correctifs : AZERTY, raccourcis personnalisés) | Accessibilité | moyenne |
| Bouton gestuel (maintenir + déplacer) | `0x1B04` détournement + `rawXY` (mouvement en HID++, pointeur immobile) | **V** : clic, gauche, droite, haut, bas | Accessibilité | moyenne |

## 5. Constat critique : le détournement survit à un plantage — V

Essai : détourner les boutons, tuer le processus (`kill -9`), relire l'état →
`flags=0x01` toujours présent ; les boutons restent muets. Fermer le
périphérique ne rend pas la main au firmware.

Décisions :

1. **Ne détourner que les boutons explicitement remappés.** Configuration par
   défaut = tout natif = aucun détournement = un plantage n'a aucun effet.
2. Arrêt propre (`SIGTERM`, `launchctl bootout`, désinstallation) : le daemon
   **annule** ses détournements avant de sortir.
3. Plantage : `launchd` relance le daemon (`KeepAlive` sur sortie anormale,
   délai court) ; au démarrage il **réimpose l'état voulu** pour les 6 contrôles,
   y compris l'annulation des détournements résiduels.
4. Dernier recours documenté : éteindre/rallumer la souris (**V** : efface
   les détournements) ou `magiclogictl reset`.

## 6. Ce qui n'est pas retenu, et pourquoi

| Idée | Raison |
|---|---|
| Event tap global | Inutile : les boutons remappés sont détournés à la source (HID++), donc aucun événement natif à filtrer, aucun doublon, aucune interférence avec le clavier TrackPoint ni avec l'event tap de MagicTrackpoint |
| Saisie exclusive (`seize`) | Inutile et dangereuse : couperait la souris si le daemon s'arrête |
| Modifier `com.apple.mouse.scaling` / défilement naturel | Réglages système globaux ; hors besoin (le DPI et l'inversion se font dans la souris) |
| Défilement lissé / vitesse | Exige de détourner la molette : une panne du daemon rendrait la molette muette. Reporté |
| API privées (`CGEventCopyIOHIDEvent`, gestes de navigation…) | Exclues par principe |
| Profils par application | Hors périmètre V1 |

## 7. Implémentations étudiées

| Projet | Licence | Apport retenu |
|---|---|---|
| OpenLogi (Rust) | MIT / Apache-2.0 | Confirme : ouverture non exclusive, SetReport synchrone (la variante asynchrone cesse de livrer les rapports après quelques centaines d'appels), index 0xFF, Surveillance de l'entrée + Accessibilité, ré-application après `0x1D4B` avec 200 ms d'attente, inclinaisons détournables sur la 2S |
| Solaar (Python) | GPL-2.0+ | Relevé de la 2S B01A ; formats des fonctions ; ré-application systématique à la reconnexion |
| logiops (C++) | GPL-3.0+ | Index 0xFF, ré-application après 100 ms |
| libratbag (C) | MIT | Rien de spécifique à la 2S |

Seules des **connaissances de protocole** (constantes, formats d'octets) sont
réutilisées ; aucun code n'est copié. Le projet est sous GPL-3.0-or-later,
comme MagicTrackpoint.

ID logiciel HID++ du projet : `0x0C` (Solaar `0x0B`, OpenRGB `0x07`, G HUB
`0x0D`, outils firmware `0x0F`), pour qu'un autre outil ouvert en même temps
ne capte pas nos réponses.
