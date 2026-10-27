# Runner GitLab sur Raspberry Pi

> Runbook pour reconstruire le runner de zéro.
> Aucun secret dans ce fichier : le token du runner existe uniquement dans
> `/etc/gitlab-runner/config.toml`, sur le Pi.

## Rôle

Le Pi exécute les jobs CI du projet qui portent le tag `rpi` :
scans de sécurité (Semgrep, gitleaks, Trivy) et build des images `linux/amd64` par émulation.

## Prérequis

- Raspberry Pi OS 64 bits : `uname -m` doit afficher `aarch64`
- Un compte avec sudo
- Un accès Maintainer au projet GitLab

## 1. Installer Docker

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
less get-docker.sh          # lire le script avant de l'exécuter
sudo sh get-docker.sh
sudo docker run --rm hello-world
```

## 2. Créer le runner dans GitLab

Settings > CI/CD > Runners > New project runner :

- Tag : `rpi`
- « Run untagged jobs » : décoché
- Copier le token `glrt-…` (il n'est affiché qu'une fois)

## 3. Installer et enregistrer gitlab-runner

```bash
curl -fsSL https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh -o runner-repo.sh
less runner-repo.sh
sudo bash runner-repo.sh
sudo apt install -y gitlab-runner
sudo gitlab-runner register --url https://gitlab.com
```

- Taper le token **au prompt**, jamais avec `--token` : en argument, il reste dans l'historique bash.
- Executor : `docker`
- Image par défaut : `alpine:3.20` (version fixe, jamais `latest`)
- Toujours avec `sudo` : sans sudo, la configuration est écrite dans `~/.gitlab-runner/`
  et le service système ne la lit pas.

## 4. Configurer le runner

Dans `/etc/gitlab-runner/config.toml` :

- `concurrent = 1` : un seul job à la fois, pour ménager la RAM du Pi
- Dans le bloc `[runners.docker]` existant :

```toml
volumes = ["/var/run/docker.sock:/var/run/docker.sock", "/cache"]
```

Puis :

```bash
sudo gitlab-runner restart
sudo gitlab-runner verify
```

## 5. Activer l'émulation amd64 au démarrage

Fichiers versionnés dans `infra/pi/` :
`activate_amd64_emulation.sh` et `binfmt-amd64.service`.

```bash
sudo install -o root -g root -m 755 infra/pi/activate_amd64_emulation.sh /usr/local/bin/
sudo cp infra/pi/binfmt-amd64.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now binfmt-amd64.service
```

## Vérifications

- [ ] Le job `test-runner` passe et son log affiche `aarch64`
- [ ] Le job `test-docker` affiche une partie « Server » dans `docker version`
- [ ] `sudo docker run --rm --platform linux/amd64 alpine:3.20 uname -m` affiche `x86_64`
- [ ] Après un redémarrage du Pi, `systemctl status binfmt-amd64` indique un succès

## Choix et risques de sécurité

| Choix | Risque | Mesure dans le lab | En production |
| --- | --- | --- | --- |
| Socket Docker monté dans les jobs | Un job contrôle le Docker du Pi, donc il est root sur le Pi | Projet privé, un seul contributeur | Runners éphémères et isolés, build sans privilèges (BuildKit rootless, buildah) |
| Token du runner | Avec le token, un attaquant peut brancher un faux runner et recevoir les jobs du projet, avec leur code et leurs variables CI | Stocké seulement dans `config.toml` (root, droits 600), jamais passé en argument | Rotation régulière, stockage dans un coffre |
| Script d'émulation lancé en root au démarrage | Élévation de privilèges s'il reste modifiable par `pi` | Installé en propriété root dans `/usr/local/bin` | Idem, plus un contrôle d'intégrité |
| Communication avec GitLab | Exposition réseau | Connexions sortantes en HTTPS uniquement, aucun port entrant ouvert | Idem, avec un filtrage des sorties |

## Dépannage

- **Le runner n'apparaît pas dans `sudo gitlab-runner list`** : `register` a probablement été lancé sans sudo.
  Supprimer `~/.gitlab-runner/` et refaire l'enregistrement avec sudo.
- **Token visible dans l'historique** : `history | grep glrt`, puis `history -d <numéro>`.
  Par prudence, recréer le runner dans GitLab, puis lancer `sudo gitlab-runner verify --delete`.
- **Build amd64 en échec après un reboot** : vérifier `systemctl status binfmt-amd64`.