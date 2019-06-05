db.sh psql postgres -c "create database $PROJDB" || exit 10
db.sh psql postgres -c "grant all privileges on database \"$PROJDB\" to gha_admin" || exit 11
db.sh psql "$PROJDB" -c "create extension if not exists pgcrypto" || exit 12
db.sh pg_restore -d "$PROJDB" "$PROJDB.dump" || exit 13
db.sh psql "$PROJDB" -c "delete from gha_vars" || exit 14
GHA2DB_PROJECT="$PROJ" PG_DB="$PROJDB" GHA2DB_LOCAL=1 vars || exit 15
GHA2DB_PROJECT="$PROJ" PG_DB="$PROJDB" GHA2DB_LOCAL=1 GHA2DB_VARS_FN_YAML="sync_vars.yaml" vars || exit 16
GHA2DB_PROJECT=$PROJ PG_DB=$PROJDB ./shared/get_repos.sh || exit 17
GHA2DB_PROJECT="$PROJ" PG_DB="$PROJDB" GHA2DB_LOCAL=1 gha2db_sync || exit 18
echo 'OK'
