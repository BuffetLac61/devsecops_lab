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
# Écart volontaire avec la doc de vault-db-injector, qui révoque avec REASSIGN OWNED + DROP OWNED :
# nos utilisateurs sont en lecture seule et ne possèdent aucun objet, un DROP ROLE suffit.
v write database/roles/app-readonly \
  db_name=postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE app_readonly;" \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl=1h \
  max_ttl=24h

echo "== KV v2 : carnet de bord de vault-db-injector"
v secrets list | grep '^vault-db-injector/' >/dev/null || v secrets enable -path=vault-db-injector -version=2 kv

echo "== Policies de vault-db-injector (chemins KV limités au préfixe du cluster : lab)"
v_stdin policy write vault-db-injector - <<'HCL'
path "vault-db-injector/data/lab/+" {
  capabilities = ["create", "update"]
}
path "vault-db-injector/metadata/lab/+" {
  capabilities = ["create", "update"]
}
path "auth/kubernetes/role/*" {
  capabilities = ["read"]
}
path "sys/leases/lookup" {
  capabilities = ["update"]
}
path "sys/health" {
  capabilities = ["read"]
}
HCL

v_stdin policy write vault-db-renewer - <<'HCL'
path "vault-db-injector/data/lab/+" {
  capabilities = ["create", "read", "update", "delete"]
}
path "vault-db-injector/metadata/lab/+" {
  capabilities = ["read", "list", "delete"]
}
path "auth/token/renew" {
  capabilities = ["update"]
}
path "auth/token/lookup" {
  capabilities = ["update"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "sys/leases/renew" {
  capabilities = ["update"]
}
path "sys/leases/lookup" {
  capabilities = ["update"]
}
path "auth/token/revoke-orphan" {
  capabilities = ["update", "sudo"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "sys/health" {
  capabilities = ["read"]
}
HCL

v_stdin policy write vault-db-revoker - <<'HCL'
path "vault-db-injector/data/lab/+" {
  capabilities = ["read", "delete"]
}
path "vault-db-injector/metadata/lab/+" {
  capabilities = ["read", "list", "delete"]
}
path "auth/token/revoke" {
  capabilities = ["update"]
}
path "auth/token/revoke-orphan" {
  capabilities = ["update", "sudo"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "sys/leases/lookup" {
  capabilities = ["update"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "sys/health" {
  capabilities = ["read"]
}
HCL

echo "== Policy de l'app : lire uniquement ses propres identifiants"
v_stdin policy write app-readonly - <<'HCL'
path "database/creds/app-readonly" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
HCL

echo "== Rôles Kubernetes : un par ServiceAccount, avec l'audience vault"
for component in vault-db-injector vault-db-injector-renewer vault-db-injector-revoker; do
  case "$component" in
    vault-db-injector)         policy=vault-db-injector ;;
    vault-db-injector-renewer) policy=vault-db-renewer ;;
    vault-db-injector-revoker) policy=vault-db-revoker ;;
  esac
  v write "auth/kubernetes/role/$component" \
    bound_service_account_names="$component" \
    bound_service_account_namespaces=vault-db-injector \
    audience=vault \
    token_policies="$policy" \
    token_ttl=1h \
    token_max_ttl=24h
done

# Le rôle de l'app porte le même nom que le rôle database, comme dans les exemples de la doc.
# token_period est obligatoire en mode projected-SA : sans lui, le token du pod expire à
# token_max_ttl et les identifiants de l'app avec lui.
v write auth/kubernetes/role/app-readonly \
  bound_service_account_names=app \
  bound_service_account_namespaces=app \
  audience=vault \
  token_policies=app-readonly \
  token_type=service \
  token_period=24h

v auth list
v secrets list
v policy list
echo "== Configuration terminée"
