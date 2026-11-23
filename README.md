# Kanban

App kanban native macOS, pilotable par Claude via la CLI `kb` avec très peu de tokens.

- **App** : projets et groupes, saisie rapide vers *To do*, glisser-déposer, thème clair/sombre.
- **CLI `kb`** : une ligne par carte, écritures silencieuses, plusieurs commandes en un appel (`kb -`).
- **Synchro** : app et CLI partagent la même base SQLite locale, l'app se met à jour en direct.

## Installer

1. Télécharge `Kanban-x.y.dmg` dans [Releases](../../releases), ouvre-le et glisse **Kanban** dans **Applications**.
2. Premier lancement : l'app n'est pas notarisée par Apple, macOS la bloque une première fois.
   Ferme l'alerte, puis **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**.
   Vérifie d'abord l'empreinte du DMG : `shasum -a 256 Kanban-x.y.dmg` doit correspondre au fichier `.sha256` de la release.
3. Pour Claude : menu **Kanban → Installer kb pour Claude…** (l'app doit être dans Applications).

Données : tout reste en local dans `~/Library/Application Support/Kanban/` (aucune connexion réseau).

Nécessite macOS 26 (Apple Silicon ou Intel).

## Utiliser avec Claude

```bash
kb                   # affiche le tableau
kb add Relancer syndic !2 +client
kb mv 3 done
```

## Compiler

```bash
./build.sh install   # app + kb + skill sur cette machine
./build.sh release   # DMG universel dans build/
```
