# devsecops_lab

> Miroir : le projet et la CI vivent sur GitLab.

Lab DevSecOps personnel : une chaîne complète, du commit jusqu'au pod en production, sécurisée à chaque étape, sur du matériel domestique (un Raspberry Pi et un serveur Ubuntu avec k3s).

## Ce que montre ce lab

- **CI sur un runner auto-hébergé** : Raspberry Pi, executor Docker, émulation amd64. L'image est taguée avec le SHA du commit, jamais `latest`, et poussée avec un identifiant éphémère propre au job.
- **Une image durcie** : multi-stage, utilisateur non-root avec un UID numérique, système de fichiers en lecture seule.
- **Un cluster k3s durci** : namespace en profil `restricted` de Pod Security Admission, aucune capability, seccomp, requests et limits sur chaque pod.
- **Des flux réseau explicites** : refus global, puis chaque flux ouvert un par un (DNS, app vers Postgres, Vault vers Postgres). Chaque règle est prouvée par un test avant/après.
- **Aucun mot de passe statique pour l'app** : Vault fabrique un utilisateur Postgres éphémère par pod, livré par [vault-db-injector](https://github.com/numberly/vault-db-injector) en mode NRI + projected-SA. La définition du pod ne contient que des marqueurs, jamais le mot de passe.

## Architecture

```
 Ton PC ──git push (SSH)──▶ GitLab.com ◀──jobs, push d'image── Raspberry Pi (runner CI)
                               ▲
                               │ git pull (clé de déploiement en lecture seule)
                               │ pull d'image (deploy token read_registry)
                               │
                  Serveur Ubuntu · k3s (sans VM, à côté de Valheim)
                  ├─ app               FastAPI + Postgres (PSA restricted, NetworkPolicies)
                  ├─ vault             Vault (mode dev) · moteur database · KV
                  ├─ vault-db-injector webhook + plugin NRI + renewer + revoker
                  └─ cert-manager      certificat TLS du webhook
```

Toutes les connexions partent des machines du lab vers GitLab : aucun port entrant n'est ouvert pour la CI.

## Arborescence

| Dossier | Contenu |
| --- | --- |
| `.gitlab-ci.yml` | Pipeline : tests du runner, build amd64 et push vers le registry |
| `app/` | API FastAPI (`/health`, `/db`), Dockerfile multi-stage, dépendances figées |
| `k8s/` | Manifests : namespace, Postgres, app, NetworkPolicies |
| `infra/k3s/` | Configuration de k3s et contournement AppArmor |
| `infra/pi/` | Émulation amd64 du runner (script et service systemd) |
| `vault/` | Configuration idempotente de Vault (`setup.sh`) et valeurs Helm de vault-db-injector |
| `docs/` | Runbooks (runner, serveur), journal, questions |

## Reconstruire le lab

1. **Runner sur le Pi** : `docs/runner-pi.md`.
2. **Serveur et k3s** : `docs/serveur-debian.md`.
3. **Postgres et l'app** : créer les Secrets (`postgres-credentials`, `gitlab-registry`), puis `kubectl apply -f k8s/00-namespace.yaml -f k8s/10-postgres.yaml -f k8s/30-networkpolicies.yaml`.
4. **Vault** : `helm install vault hashicorp/vault -n vault --set server.dev.enabled=true --set injector.enabled=false`, puis `kubectl apply -f k8s/31-postgres-from-vault.yaml` et `./vault/setup.sh`.
5. **vault-db-injector** : cert-manager, namespace `vault-db-injector` en profil `privileged`, puis installation du chart 3.2.9 sans `templates/cnp.yml` (voir `vault/README.md`).
6. **L'app en identifiants dynamiques** : `kubectl apply -f k8s/20-app.yaml`.

## Choix et compromis assumés

| Choix | Raison | Ce que changerait la production |
| --- | --- | --- |
| k3s directement sur l'hôte | VT-x désactivé dans le BIOS | Une VM ou des nœuds dédiés |
| `kernel.apparmor_restrict_unprivileged_unconfined = 0` | Bug containerd sur Ubuntu 26.04 ([#14485](https://github.com/containerd/containerd/issues/14485)) | Profil AppArmor corrigé, retrait après la correction amont |
| Vault en mode dev | Lab éphémère, configuration rejouable | Stockage Raft, déverrouillage automatique, TLS, audit |
| Connexion Vault vers Postgres sans TLS | Simplicité du lab | `sslmode=require` ou `verify-full` |
| Révocation par `DROP ROLE` | Utilisateurs en lecture seule, qui ne possèdent aucun objet | Selon le modèle de droits de l'application |
| Audience par défaut pour les composants de vault-db-injector | Le chart 3.2.9 ne leur monte pas de jeton d'audience `vault` | Jeton projeté d'audience `vault` |
| `CiliumNetworkPolicy` retirée du chart | Le cluster n'utilise pas Cilium | NetworkPolicy standard équivalente |
| Socket Docker monté dans les jobs | Build d'images sur le Pi | Runners éphémères isolés, build sans privilèges |

## État au 03/11/2026

- **DJ1 terminée** : runner, pipeline, cluster, déploiement durci, NetworkPolicies prouvées.
- **DJ2 en cours** : Vault, moteur database et vault-db-injector installés, avec ses quatre composants en fonctionnement. La bascule de l'app sur les identifiants dynamiques est prête dans `k8s/20-app.yaml`, sa validation finale reste à faire.
- **Suite** : Semgrep, gitleaks et Trivy dans la CI, policies Kyverno (dont la protection du socket NRI), Falco, puis un serveur MCP en lecture seule sur le lab.

Le détail des incidents et des leçons est dans `docs/journal.md`.
