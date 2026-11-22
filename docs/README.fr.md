# MagicLogi

**Remplaçant minimaliste de Logitech Options+ pour la MX Anywhere 2S en Bluetooth, sur macOS.**

Un petit agent en arrière-plan, sans fenêtre ni icône : il règle la souris
elle-même (DPI, sens de la molette) et donne aux boutons les actions de votre
choix, y compris le bouton gestuel d'Options+. Pas de compte, pas de réseau,
pas de télémétrie, pas de mise à jour automatique, pas de droits administrateur.
Sans lien avec Logitech.

| Fonction | Comment | Vérifié sur le matériel |
|---|---|---|
| Résolution (DPI) 200–4000 | réglée dans la souris (HID++) | oui |
| Sens de la molette, souris seule | réglé dans la souris (le trackpad n'est pas touché) | oui |
| Boutons latéraux, bouton derrière la molette, inclinaisons | natifs, ou remappés (raccourci, Mission Control, espaces, boutons 4/5…) | oui |
| Bouton gestuel | clic bref = clic central ; maintenir + déplacer : espaces gauche/droite, Mission Control, fenêtres de l'app | oui |
| Défilement horizontal | natif (inclinaison de la molette) | oui |
| Reconnexion, extinction/rallumage de la souris | réglages réappliqués automatiquement (~1 s) | oui |
| Batterie | lue, journalisée, `magiclogictl status` | oui |

Modèle unique : `046D:B01A`, Bluetooth direct. Aucun autre périphérique n'est
ouvert ni modifié (le clavier TrackPoint et le trackpad sont ignorés).

## Installation

macOS 13+, Apple Silicon. Deux façons, qui installent les mêmes fichiers pour
votre compte seulement :

**Image disque (le plus simple).** Télécharger `MagicLogi-<version>.dmg` sur la
[page des versions](https://github.com/phocean/MagicLogi/releases), l'ouvrir,
double-cliquer sur **Install MagicLogi** puis **Continue** jusqu'à « All
permissions granted ». Tout est signé Developer ID et notarisé par Apple.

**Depuis les sources** (Xcode ou ses outils en ligne de commande) :

```bash
make install
```

Compile, lance les tests, signe (certificat Developer ID / Apple Development du
trousseau s'il existe, sinon ad hoc), installe dans `~/.local/bin`, crée
`~/.config/magiclogi/config.toml` (tout natif) et démarre l'agent `launchd`.

Puis accorder, dans **Réglages Système > Confidentialité et sécurité** :

1. **Surveillance de l'entrée** → `magiclogid` (indispensable : sans elle, macOS
   refuse d'ouvrir la souris) ;
2. **Accessibilité** → `magiclogid` (seulement si vous remappez un bouton).

`magiclogictl permissions` relance l'agent, indique l'état des deux et ouvre
la première manquante. Avec une signature Developer ID ou Apple Development, ces autorisations
survivent aux réinstallations ; en ad hoc, il faut les redonner à chaque fois.

## Configuration

Éditer `~/.config/magiclogi/config.toml` (exemple commenté :
[config/config.example.toml](../config/config.example.toml)), puis :

```bash
magiclogictl reload
```

Exemple proche d'Options+ :

```toml
[pointer]
dpi = 1200

[scroll]
invert = false         # true = molette de la souris inversée, trackpad inchangé

[buttons]
middle = "gestures"    # bouton derrière la molette = bouton gestuel
back = "back"
forward = "forward"

[gestures]
click = "middle-click" # appui bref = clic central habituel
left = "space-left"
right = "space-right"
```

Clé absente = la souris n'est pas touchée sur ce point. Une configuration
invalide est refusée en entier (`magiclogictl check` indique la ligne fautive) :
au démarrage la souris reste telle quelle, au rechargement l'ancienne
configuration est conservée.

## Commandes

| Commande | Effet |
|---|---|
| `magiclogictl status` | état, batterie, DPI, boutons détournés, autorisations |
| `magiclogictl permissions` | relance, état et ouverture des autorisations manquantes |
| `magiclogictl reload` | relit la configuration |
| `magiclogictl start` / `stop` / `restart` | pilote l'agent |
| `magiclogictl log [minutes]` | journal (Unified Logging, sous-système `com.jcbaptiste.magiclogi`) |
| `magiclogictl diag` | rapport HID++ en lecture seule (fonctions, DPI, boutons, batterie) |
| `magiclogictl events [s] [--divert]` | affiche ce qu'envoient boutons et molette |
| `magiclogictl reset` | boutons natifs, molette non inversée, DPI d'usine (agent arrêté) |

## Désinstallation

```bash
magiclogictl stop && magiclogictl reset   # facultatif : remet DPI et molette d'usine
make uninstall                            # garde la configuration ; --purge pour tout effacer
```

## Si un bouton ne répond plus

Un bouton remappé est « détourné » dans la souris ; si l'agent meurt
brutalement, `launchd` le relance en moins d'une seconde et il reprend la main.
En dernier recours : **éteindre puis rallumer la souris** (elle oublie alors
tout détournement), ou `magiclogictl reset`.

## Documentation

- [etude-faisabilite.md](etude-faisabilite.md) — étude technique, matrice de faisabilité, preuves
- [architecture.md](architecture.md) — architecture, permissions, surface d'attaque, limites, tests et mesures

Licence : GNU GPL v3 ou ultérieure. Aucun code tiers ; seules des
connaissances de protocole HID++ (Solaar, OpenLogi, logiops) sont réutilisées.
