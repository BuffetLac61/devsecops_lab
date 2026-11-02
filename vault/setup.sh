#!/bin/bash
# Configure Vault (mode dev) pour le lab.
# À relancer après chaque redémarrage de vault-0 : le mode dev garde tout en mémoire.
set -euo pipefail

NS=vault
POD=vault-0

# Lance une commande vault dans le pod, avec le token root du mode dev.
# "root" est la valeur par défaut du mode dev : ce n'est pas un vrai secret,
# mais un vrai Vault n'utilise jamais le token root au quotidien.
v() {
  kubectl -n "$NS" exec "$POD" -- env VAULT_TOKEN=root vault "$@"
}

echo "== État de Vault"
v status

echo "== Authentification Kubernetes"
# On n'active la méthode que si elle ne l'est pas déjà : le script peut être relancé sans erreur.
v auth list | grep -q '^kubernetes/' || v auth enable kubernetes
v write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"

v auth list
