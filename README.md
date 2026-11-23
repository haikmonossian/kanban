# Kanban

App kanban native macOS, pilotable par Claude via la CLI `kb` avec très peu de tokens.

- **App** : projets en onglets, saisie rapide vers *To do*, glisser-déposer, thème clair/sombre.
- **CLI `kb`** : une ligne par carte, écritures silencieuses, plusieurs commandes en un appel (`kb -`).
- **Synchro** : app et CLI partagent la même base SQLite, l'app se met à jour en direct.

```bash
./build.sh install   # installe l'app, la CLI kb et la skill Claude
kb                   # affiche le tableau
kb add Relancer syndic !2 +client
kb mv 3 done
```

Nécessite macOS 26 et les Command Line Tools (Swift 6).
