# Journal du lab

## DJ1 – Socle : runner, app, k3s, déploiement durci

**Statut** : terminée le 02/11/2026 · **Prévu** : 4 h · **Réel** : à compléter

### Séances

| Date | Ce qui a été fait |
| --- | --- |
| 27/10 | Repo GitLab et miroir GitHub, runner sur le Pi (Docker, tag `rpi`, émulation amd64) |
| 29/10 | App FastAPI, Dockerfile multi-stage non-root, pipeline de build et push vers le registry |
| 31/10 | Correctif de journalisation, mesures du serveur, diagnostic de virtualisation, k3s sur l'hôte |
| 02/11 | Déploiement durci de Postgres et de l'app, trois incidents résolus, NetworkPolicies |

### Ce qui est livré

- Runner GitLab sur le Raspberry Pi : executor Docker, tag `rpi`, runners partagés désactivés
- Miroir GitLab vers GitHub, limité aux branches protégées
- Image de l'app construite par la CI, taguée avec le SHA du commit, jamais `latest`
- k3s installé directement sur le serveur (plan B), configuration versionnée dans `infra/k3s/`
- Namespace `app` en profil `restricted` de Pod Security Admission
- Postgres (StatefulSet) et app (Deployment) : non-root, système de fichiers en lecture seule, aucune capability, requests et limits
- NetworkPolicies : refus global, DNS autorisé, app vers Postgres uniquement

### Écarts au plan et décisions

- **Ordre inversé** : Pi et GitLab d'abord, serveur ensuite (serveur indisponible au départ).
- **Plan B sans VM** : VT-x désactivé dans le BIOS, pas de câble pour y accéder. k3s partage donc le noyau de l'hôte avec Valheim.
- **Contournement AppArmor** : `kernel.apparmor_restrict_unprivileged_unconfined = 0`. Risque accepté (serveur avec un seul utilisateur humain, lab). Retour arrière prévu dès que k3s embarquera la correction de containerd (#14485).

### Incidents et pièges

| Problème | Cause | Correction | Leçon |
| --- | --- | --- | --- |
| Runner absent de `/etc/gitlab-runner/config.toml` | `register` lancé sans `sudo` | Réenregistrement avec `sudo` | Le service lit la config système, pas celle de l'utilisateur |
| Token du runner dans l'historique bash | Passé en argument `--token` | `history -d`, saisie au prompt | Un secret passé en argument fuit |
| Pipelines refusés par GitLab | Jobs partis vers les runners partagés de gitlab.com | Runners partagés désactivés, tag `rpi` | Savoir sur quelle machine tourne son code |
| Jobs en échec sans avoir tourné | Pi éteint plus de 24 h | « Run again » | Un job sans runner expire |
| `kvm-ok` négatif trompeur | Lancé sans `sudo` | Relancé en root | Vérifier en root avant de conclure |
| Mot de passe Valheim visible dans `ps` | Secret en argument de processus | À changer ; option `hidepid` | Tout utilisateur voit les arguments des processus |
| Deploy token exposé | Collé dans la commande `read` | Révoqué et remplacé, saisie avec `read -s` | Un secret qui fuit se révoque, pas seulement s'efface |
| `InvalidImageName` | Chemin de l'image collé deux fois | Tag seul après le `:` | Anatomie : `registre/chemin/nom:tag` |
| `CrashLoopBackOff` de l'app | `TabError` : tabulations dans `main.py` | `expand`, puis `py_compile` avant de pousser | Vérifier avant de pousser (shift-left) |
| Postgres jamais prêt | AppArmor bloque les signaux entre processus (Ubuntu 26.04, noyau 7.0.0-42) | Réglage `sysctl` documenté | Lire `dmesg`, remonter jusqu'au bug amont |

### Preuves validées

- [x] Job `test-runner` sur le runner `rpi`, architecture `aarch64`
- [x] Job `test-docker` : le job parle au Docker du Pi
- [x] Image `app:<sha>` dans le registry
- [x] `kubectl get nodes` : nœud Ready
- [x] `/health` et `/db` répondent (`connected_as: app`)
- [x] Sans NetworkPolicy, Postgres joignable depuis `default` ; avec, `no response`
- [ ] Preuve AppArmor : `/proc/1/attr/current` sans `//&unconfined`, plus de refus dans `dmesg`

### Mesures

- Serveur : 4 cœurs, 12 Gio disponibles avec Valheim (environ 1,7 Go), 81 Go libres
- Premier build de l'image en émulation : 2 min 10 s
- Build après une modification de `main.py` (cache) : à compléter

### Dette technique

- L'app se connecte avec le superutilisateur Postgres → DJ2 (Vault)
- Le build est relancé à chaque commit, même sans changement de l'app → DJ3 (`rules: changes`)
- Aucun nettoyage du registry → DJ3
- Aucune vérification de syntaxe en CI → DJ3
- Secrets Kubernetes non chiffrés dans la base de k3s (`secrets-encryption`)
- Contournement AppArmor à retirer après la correction amont
- Mot de passe Valheim à changer

### À raconter en entretien

- L'incident AppArmor : une mise à jour du noyau casse Postgres, diagnostic par les logs puis `dmesg`, bug containerd ouvert la semaine même, contournement choisi en connaissant le risque, retour arrière prévu.
- La fuite du deploy token : révocation et remplacement immédiats, puis correction de la méthode de saisie.
- Les NetworkPolicies prouvées par un test avant/après, et non supposées.
