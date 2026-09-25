# ent core: temporary aggregator that sources the split modules.
# New code should source the focused modules directly; git-ent does.

_ENT_CORE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ENT_CORE_LIB/output.sh"
source "$_ENT_CORE_LIB/args.sh"
source "$_ENT_CORE_LIB/run.sh"
source "$_ENT_CORE_LIB/prompt.sh"
source "$_ENT_CORE_LIB/log.sh"
source "$_ENT_CORE_LIB/tree.sh"
source "$_ENT_CORE_LIB/state.sh"
source "$_ENT_CORE_LIB/paths.sh"
