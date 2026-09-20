# ent view: a full-screen browser over every worktree, used by `ent status` and
# `ent log`. Tab moves between worktrees, the body scrolls, q quits.
#
# On a terminal it takes over the screen (the "alternate screen", the same trick
# less and vim use, so your scrollback comes back untouched on exit).
# When the output is piped or redirected, it prints every worktree in order
# instead, so `ent status | grep ...` and scripts still work.

VIEW_BRANCHES=() VIEW_PATHS=()
VIEW_COLOR=never        # renderers pass this to git -c color.ui=...

# view_targets: every branch with a worktree, in `ent list` order (main, branches,
# then each branch's twigs).
view_targets() {
  VIEW_BRANCHES=() VIEW_PATHS=()
  local b kid tops kids
  _view_add "$S_MAIN"
  top_branches; tops=(${REPLY_LIST[@]+"${REPLY_LIST[@]}"})
  for b in ${tops[@]+"${tops[@]}"}; do
    _view_add "$b"
    children_of "$b"; kids=(${REPLY_LIST[@]+"${REPLY_LIST[@]}"})
    for kid in ${kids[@]+"${kids[@]}"}; do _view_add "$kid"; done
  done
}
_view_add() {
  wt_path_of "$1" || return 0
  [[ -d "$REPLY" ]] || return 0
  VIEW_BRANCHES+=("$1"); VIEW_PATHS+=("$REPLY")
}

# view_run <title> <render-fn>: <render-fn> <branch> <path> prints what to show.
view_run() {
  local title="$1" render="$2" i=0
  ensure_ent
  view_targets
  (( ${#VIEW_BRANCHES[@]} )) || die "no worktrees to show"

  if [[ ! -t 1 || ! -t 0 ]]; then
    VIEW_COLOR=never     # piped: plain text, like git's own commands
    while (( i < ${#VIEW_BRANCHES[@]} )); do
      printf '=== %s  (%s)\n' "${VIEW_BRANCHES[$i]}" "${VIEW_PATHS[$i]}"
      "$render" "${VIEW_BRANCHES[$i]}" "${VIEW_PATHS[$i]}"
      printf '\n'
      i=$((i + 1))
    done
    return 0
  fi

  VIEW_COLOR=always      # a terminal: the viewer captures output, so force color on
  _view_screen "$title" "$render" "$(_view_start)"
}

# _view_start: index of the worktree you are standing in, else 0 (main).
_view_start() {
  local cur i=0
  cur="$(ent_branch_of_cwd 2>/dev/null || true)"
  while (( i < ${#VIEW_BRANCHES[@]} )); do
    [[ "${VIEW_BRANCHES[$i]}" == "$cur" ]] && { printf '%s' "$i"; return; }
    i=$((i + 1))
  done
  printf '0'
}

# _view_screen: the interactive part.
_view_screen() {
  local title="$1" render="$2"
  local sel="${3:-0}" top=0 rows cols lines_count key rest redraw=1
  local -a body

  trap '_view_leave' EXIT INT TERM
  printf '\033[?1049h\033[?25l'          # alternate screen, hide cursor

  while true; do
    rows="$(tput lines 2>/dev/null || echo 24)"
    cols="$(tput cols  2>/dev/null || echo 80)"
    local page=$((rows - 4))
    (( page > 0 )) || page=1

    if (( redraw )); then
      body=()
      while IFS= read -r line; do body+=("$line"); done < <("$render" "${VIEW_BRANCHES[$sel]}" "${VIEW_PATHS[$sel]}" 2>&1)
      lines_count=${#body[@]}
      redraw=0
    fi
    (( top > lines_count - page )) && top=$((lines_count - page))
    (( top < 0 )) && top=0

    printf '\033[H\033[2J'
    _view_header "$title" "$sel" "$cols"
    local i=$top end=$((top + page))
    while (( i < end && i < lines_count )); do
      printf '%s\n' "${body[$i]}"
      i=$((i + 1))
    done
    printf '\033[%d;1H\033[7m %-*s\033[0m' "$rows" "$((cols - 1))" \
      "tab/shift-tab worktree   j/k or arrows scroll   space/b page   g/G top/bottom   r reload   q quit  [$((sel + 1))/${#VIEW_BRANCHES[@]}]"

    IFS= read -rsn1 key || break
    if [[ "$key" == $'\033' ]]; then      # an escape sequence: arrows, shift-tab
      read -rsn2 -t 0.05 rest || rest=""
      case "$rest" in
        '[A') key=k ;; '[B') key=j ;; '[C') key=$'\t' ;; '[D') key=P ;; '[Z') key=P ;;
        '[5') read -rsn1 -t 0.05 _ || true; key=b ;;
        '[6') read -rsn1 -t 0.05 _ || true; key=' ' ;;
        '')   key=q ;;
        *)    key="" ;;
      esac
    fi
    case "$key" in
      $'\t'|l) sel=$(( (sel + 1) % ${#VIEW_BRANCHES[@]} )); top=0; redraw=1 ;;
      P|h)     sel=$(( (sel - 1 + ${#VIEW_BRANCHES[@]}) % ${#VIEW_BRANCHES[@]} )); top=0; redraw=1 ;;
      j)       top=$((top + 1)) ;;
      k)       top=$((top - 1)) ;;
      ' ')     top=$((top + page)) ;;
      b)       top=$((top - page)) ;;
      g)       top=0 ;;
      G)       top=$((lines_count - page)) ;;
      r)       redraw=1 ;;
      q)       break ;;
    esac
  done
  _view_leave
  trap - EXIT INT TERM
}

# _view_header: the worktree tabs, with the selected one highlighted.
_view_header() {
  local title="$1" sel="$2" cols="$3" i=0 line=""
  printf '\033[1m%s\033[0m\n' "$title"
  while (( i < ${#VIEW_BRANCHES[@]} )); do
    if (( i == sel )); then line+=$'\033[7m '"${VIEW_BRANCHES[$i]}"$' \033[0m'
    else                     line+=" ${VIEW_BRANCHES[$i]} "; fi
    i=$((i + 1))
  done
  printf '%s\n\n' "$line"
}

_view_leave() { printf '\033[?25h\033[?1049l'; }
