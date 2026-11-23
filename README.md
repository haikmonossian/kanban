# Kanban

Kanban natif macOS (SwiftUI, Liquid Glass) avec une CLI `kb` ultra-compacte pour que Claude le lise et le modifie en dépensant le moins de tokens possible.

- **App** : projets en onglets dans la barre latérale (repliable avec ⌃⌘S), saisie rapide en haut qui ajoute dans *To do*, kanban en dessous, glisser-déposer, mise à jour en direct quand `kb` modifie la base.
- **CLI** `kb` : sorties d'une ligne par carte, écritures silencieuses, mode batch `kb -`. Voir `kb help` ou [skill/SKILL.md](skill/SKILL.md).
- **Stockage** : SQLite (WAL) dans `~/Library/Application Support/Kanban/kanban.sqlite` (`KB_DB` pour en utiliser une autre).

## Syntaxe rapide

`Relancer syndic !2 +client` → priorité 2, étiquette `client`. Même syntaxe dans l'app et dans `kb add`.

```bash
kb                      # tableau du projet courant (dernière colonne repliée)
kb add Écrire la doc !1 +docs
kb mv 12 done
kb - <<'EOF'
add "Préparer AG" @perso
note 12 "bloqué par l'API"
EOF
```

## Build

Nécessite les Command Line Tools (Swift 6) et macOS 26.

```bash
./build.sh            # build/Kanban.app
./build.sh install    # /Applications/Kanban.app + ~/.local/bin/kb + skill Claude
```
