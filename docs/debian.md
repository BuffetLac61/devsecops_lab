# Serveur du lab : Valheim et k3s

> Runbook pour reconstruire le serveur du lab.
> Aucun secret dans ce fichier : ni mot de passe Valheim, ni kubeconfig, ni adresse IP.
> Le repo est copié publiquement sur GitHub par le miroir : rien de sensible ne doit y entrer.

## Rôle

- Héberge le serveur Valheim, qui ne doit pas être perturbé par le lab.
- Héberge le cluster k3s à un seul nœud du lab, installé directement sur l'hôte (plan B, sans VM).

## Caractéristiques mesurées (31/10/2026)

| Élément | Valeur |
| --- | --- |
| OS | Ubuntu, famille Debian (dépôts `resolute`) |
| CPU | Intel Core i5-7500T, 4 cœurs |
| RAM | 14 Gio visibles, 12 Gio disponibles avec Valheim lancé |
| Valheim | environ 1,7 Go de RAM au repos |
| Disque | 81 Go libres sur `/` |
| Virtualisation | VT-x désactivé dans le BIOS, donc pas de VM possible |

Commandes de mesure :

```bash
free -h
nproc
df -h /
ps aux --sort=-rss | head -5
```

## 0. Avant toute intervention : sauvegarder Valheim

Les mondes sont dans `/home/valheim/saves` (option `-savedir` du serveur).

```bash
sudo tar czf ~/valheim-backup-$(date +%F).tar.gz -C /home/valheim saves
sudo chown $USER: ~/valheim-backup-*.tar.gz
```

Puis copier l'archive hors du serveur (`scp` vers le PC) : une sauvegarde sur la même machine
ne protège pas d'une panne de disque.

## 1. Diagnostic de la virtualisation

```bash
sudo apt install -y cpu-checker
sudo kvm-ok                                   # toujours avec sudo, sinon le résultat est incomplet
lscpu | grep -iE 'model name|virtualization'
systemd-detect-virt
```

Résultat du 31/10/2026 :

- `systemd-detect-virt` → `none` : machine physique.
- Le i5-7500T gère VT-x, mais `lscpu` n'affiche aucune ligne « Virtualization » :
  la fonction est désactivée dans le BIOS, et le noyau la masque.
- Décision : plan B, k3s directement sur l'hôte.

Pour activer la VM plus tard : écran et clavier branchés, puis `sudo systemctl reboot --firmware-setup`,
et passer « Intel Virtualization Technology » sur Enabled.

## 2. Installer k3s sur l'hôte

Fichier versionné : `infra/k3s/config.yaml`.

```yaml
disable:
  - traefik       # pas d'ingress : accès par port-forward
  - servicelb     # k3s n'occupe aucun port de l'hôte
write-kubeconfig-mode: "0600"
kubelet-arg:
  - "system-reserved=memory=1Gi"
  - "kube-reserved=memory=1Gi"
  - "eviction-hard=memory.available<500Mi"
```

Depuis le PC, copier la configuration sur le serveur :

```bash
scp infra/k3s/config.yaml <utilisateur>@<serveur>:~/
```

Sur le serveur :

```bash
sudo mkdir -p /etc/rancher/k3s
sudo cp ~/config.yaml /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io -o install-k3s.sh
less install-k3s.sh              # lire le script avant de l'exécuter
sudo sh install-k3s.sh
```

## 3. Accès au cluster

Le kubeconfig donne les droits d'administrateur du cluster : il reste lisible par un seul utilisateur.

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER: ~/.kube/config && chmod 600 ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc && source ~/.bashrc
```

Le cluster se pilote depuis le serveur. Le kubeconfig n'est pas copié sur le PC.

## Vérifications

- [ ] `kubectl get nodes` : le nœud est en `Ready`
- [ ] `kubectl get pods -A` : coredns, local-path-provisioner et metrics-server en `Running`
- [ ] `free -h` : au moins 2 Go disponibles avec Valheim et k3s lancés
- [ ] `ls -l /etc/rancher/k3s/k3s.yaml` : droits `-rw-------` et propriétaire root
- [ ] Valheim toujours joignable par les joueurs

## Choix et risques de sécurité

| Choix | Risque | Mesure |
| --- | --- | --- |
| k3s sur l'hôte, sans VM | Un pod qui s'échappe de son conteneur se retrouve sur l'hôte, à côté de Valheim | Policies Kyverno (DJ3) : pas de conteneur privilégié, `runAsNonRoot` |
| Pods et Valheim sur la même RAM | Un pod gourmand prive Valheim de mémoire | 2 Go réservés à l'hôte, expulsion sous 500 Mo libres, requests et limits sur chaque pod |
| API du cluster sur le port 6443 | Exposition de l'administration du cluster | Port jamais redirigé sur la box : accessible uniquement depuis le réseau local |
| kubeconfig administrateur | Lecture du fichier = contrôle du cluster, donc root sur l'hôte | Droits 600, une seule copie, jamais dans le repo |
| Mot de passe Valheim en argument de processus | Visible par tous les utilisateurs de la machine avec `ps`, et par Falco en DJ4 | Mot de passe changé ; option possible : monter `/proc` avec `hidepid=invisible` |

## Revenir en arrière

```bash
sudo /usr/local/bin/k3s-uninstall.sh
rm -f ~/.kube/config
```

Le script supprime k3s, ses services, ses interfaces réseau et ses données (`/var/lib/rancher`).

## Dépannage

- **`kvm-ok` dit que le CPU ne gère pas KVM** : relancer avec `sudo` avant de conclure.
- **`kubectl` répond « connection refused » ou « permission denied »** : vérifier `echo $KUBECONFIG`
  et les droits de `~/.kube/config`.
- **Nœud en `NotReady`** : suivre les logs avec `sudo journalctl -u k3s -f`.
- **Valheim ralentit** : `kubectl top nodes` et `kubectl top pods -A` pour repérer le pod gourmand.
