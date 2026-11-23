# Kanban

App kanban native macOS, pilotable par Claude via la CLI `kb` en dépensant très peu de tokens.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img alt="Kanban : barre latérale avec projets et groupes, saisie rapide, colonnes To do, En cours, Revue et Terminé" src="docs/screenshot-light.png">
</picture>

## Fonctionnalités

**Organisation**
- Projets dans une barre latérale repliable, rangés en **groupes** (glisser un projet sur un autre crée un groupe).
- **Saisie rapide** en haut : `Relancer le client !2 +urgent +"à valider"` crée la carte avec priorité et étiquettes.
- Cartes avec description, priorité (1 à 3), étiquettes ; glisser-déposer entre colonnes.

**Colonnes**
- Couleur au choix (clic sur la pastille), réorganisation par la poignée ⠿.
- Colonne « **terminée** » : cartes barrées et estompées, non comptées comme ouvertes.
- **Modèle de colonnes** : enregistre les colonnes d'un projet, chaque nouveau projet les reprend.

**Mac**
- Design Liquid Glass, thème Système / Clair / Sombre (⇧⌘D).
- Menu du Dock : 3 projets récents + Nouveau projet.
- Données 100 % locales (SQLite), aucune connexion réseau.

**Claude**
- CLI `kb` : une ligne par carte, écritures silencieuses, plusieurs commandes en un appel.
- L'app se met à jour en direct quand Claude modifie le tableau.

## Installer

1. Télécharge `Kanban-x.y.dmg` dans [Releases](../../releases), glisse **Kanban** dans **Applications**.
2. L'app n'est pas notarisée par Apple : au premier lancement, ferme l'alerte puis
   **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**.
   Vérifie l'empreinte : `shasum -a 256 Kanban-x.y.dmg` doit correspondre au `.sha256` de la release.
3. Pour Claude : menu **Kanban → Installer kb pour Claude…**

Nécessite macOS 26 (Apple Silicon ou Intel).

## Utiliser avec Claude

Demande simplement « ajoute X à mon kanban » ou « passe la 3 en cours ». Ou directement :

```bash
kb                                  # tableau du projet courant
kb add Relancer syndic !2 +client   # -> id
kb mv 3 done
kb - <<'EOF'                        # plusieurs opérations en un appel
add "Préparer AG" @perso
note 12 "bloqué par l'API"
EOF
```

`kb help` liste toutes les commandes.

## Compiler

```bash
./build.sh install   # app + kb + skill Claude sur cette machine
./build.sh release   # DMG universel dans build/
```
