#!/bin/bash
# Configure Vault (mode dev) et Postgres pour le lab.
# À relancer après chaque redémarrage de vault-0 : le mode dev garde tout en mémoire.
# Le script est idempotent : on peut le relancer sans risque.
set -euo pipefail

NS=vault
POD=vault-0

# Lance une commande vault dans le pod, avec le token root du mode dev.
# "root" est la valeur par défaut du mode dev : un vrai Vault n'utilise jamais le token root au quotidien.
v() {
  kubectl -n "$NS" exec "$POD" -- env VAULT_TOKEN=root vault "$@"
}

# Même chose, avec des données envoyées sur l'entrée standard :
# un secret ne doit jamais passer en argument, où il serait visible avec ps.
v_stdin() {
  kubectl -n "$NS" exec -i "$POD" -- env VAULT_TOKEN=root vault "$@"
}

echo "== État de Vault"
v status

echo "== Authentification Kubernetes"
v auth list | grep '^kubernetes/' >/dev/null || v auth enable kubernetes
v write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"

echo "== Postgres : rôle de groupe en lecture seule et utilisateur dédié à Vault"
# Mot de passe temporaire : il ne sert qu'à la première connexion de Vault,
# qui le remplace aussitôt par un mot de passe que lui seul connaît (rotate-root plus bas).
VAULT_PG_PASSWORD="$(openssl rand -hex 24)"
kubectl -n app exec -i postgres-0 -- psql -v ON_ERROR_STOP=1 -q -U app -d app <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_readonly') THEN
    CREATE ROLE app_readonly NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vault') THEN
    CREATE ROLE vault LOGIN CREATEROLE;
  END IF;
END
\$\$;
ALTER ROLE vault PASSWORD '${VAULT_PG_PASSWORD}';
GRANT app_readonly TO vault WITH ADMIN OPTION;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_readonly;
SQL

echo "== Moteur de secrets database"
v secrets list | grep '^database/' >/dev/null || v secrets enable database

# Connexion de Vault à Postgres. Le JSON passe par l'entrée standard :
# le mot de passe n'apparaît jamais dans la liste des processus.
v_stdin write database/config/postgres - <<JSON
{
  "plugin_name": "postgresql-database-plugin",
  "connection_url": "postgresql://{{username}}:{{password}}@postgres.app.svc.cluster.local:5432/app?sslmode=disable",
  "username": "vault",
  "password": "${VAULT_PG_PASSWORD}",
  "allowed_roles": "app-readonly"
}
JSON
unset VAULT_PG_PASSWORD

# Vault remplace le mot de passe de son utilisateur Postgres : plus personne d'autre ne le connaît.
v write -force database/rotate-root/postgres

echo "== Rôle app-readonly : des utilisateurs éphémères, membres de app_readonly"
v write database/roles/app-readonly \
  db_name=postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE app_readonly;" \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl=1h \
  max_ttl=24h

v auth list
v secrets list
echo "== Configuration terminée"
