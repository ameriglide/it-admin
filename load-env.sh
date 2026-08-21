# shellcheck shell=bash
# Safe loader for the ag-admin .env: the 1Password-mounted FIFO (unquoted
# values) or a regular file in either format — plain `source` word-splits
# unquoted values containing spaces and executes the second word as a command.
# Values are taken literally (no expansion); surrounding quotes are stripped.
# Usage:
#   source ~/Projects/ag-admin/load-env.sh
# Optionally set AG_ADMIN_ENV to point at a different env file first.
#
# This loads .env only. Machine-written values -- rotated SSM activations,
# Tailscale keys, Vector tokens -- are NOT here: they live in the 1Password
# item ag-admin-runtime, because .env is a read-only mount that no script can
# write to. Reading that item costs several seconds, so it is not loaded on
# every source; fetch what you need directly:
#
#   op item get ag-admin-runtime --vault ag-admin-runtime \
#      --account ameriglide.1password.com --fields label=SSM_ACTIVATION_ID --reveal
#
# TypeScript entrypoints use src/lib/op-runtime.ts for the same thing.
_ag_admin_env="${AG_ADMIN_ENV:-$HOME/Projects/ag-admin/.env}"
while IFS= read -r _line; do
  case "$_line" in \#*|'') continue ;; esac
  case "$_line" in
    *=*)
      _val="${_line#*=}"
      case "$_val" in
        \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;;
        \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;;
      esac
      export "${_line%%=*}=$_val" ;;
  esac
done < "$_ag_admin_env"
unset _line _val _ag_admin_env
