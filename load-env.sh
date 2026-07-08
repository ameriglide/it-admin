# Safe loader for the 1Password-mounted .env (values are unquoted; plain
# `source` word-splits values containing spaces). Usage:
#   source ~/Projects/ag-admin/load-env.sh
# Optionally set AG_ADMIN_ENV to point at a different env file first.
_ag_admin_env="${AG_ADMIN_ENV:-$HOME/Projects/ag-admin/.env}"
while IFS= read -r _line; do
  case "$_line" in \#*|'') continue ;; esac
  case "$_line" in *=*) export "${_line%%=*}=${_line#*=}" ;; esac
done < "$_ag_admin_env"
unset _line _ag_admin_env
