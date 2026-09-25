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
#
# Drawing rule: move the cursor home and overwrite line by line, clearing each line
# as it goes (\033[K) and the rest of the screen at the end (\033[J). Wiping the
# whole screen first (\033[2J) would leave it blank for an instant on every keypress,
# which reads as flicker.
VIEW_CHROME=3              # title + tab bar + blank line, above the body
VIEW_LEFT=0                # guard: _view_leave runs only once per session

# _view_mouse_off: disable any mouse-reporting mode a previous program may have left on.
# (Windows Terminal + Git Bash can inherit these from another TUI.)
_view_mouse_off() {
  printf '\033[?1003l\033[?1002l\033[?1000l\033[?1006l\033[?1015l'
}

_view_screen() {
  local title="$1" render="$2"
  local sel="${3:-0}" top=0 rows cols lines_count key rest redraw=1 page
  local -a body

  local saved_tty=""
  [[ -t 0 ]] && saved_tty="$(stty -g 2>/dev/null)" || true
  trap '_view_leave "$saved_tty"' EXIT INT TERM
  VIEW_LEFT=0

  _view_mouse_off
  printf '\033[?1049h\033[?25l'          # alternate screen, hide cursor

  while true; do
    rows="$(tput lines 2>/dev/null || echo 24)"
    cols="$(tput cols  2>/dev/null || echo 80)"
    page=$((rows - VIEW_CHROME - 1))     # -1 for the key bar on the last row
    (( page > 0 )) || page=1

    if (( redraw )); then
      body=()
      while IFS= read -r line; do body+=("$line"); done < <("$render" "${VIEW_BRANCHES[$sel]}" "${VIEW_PATHS[$sel]}" 2>&1)
      lines_count=${#body[@]}
      redraw=0
    fi
    (( top > lines_count - page )) && top=$((lines_count - page))
    (( top < 0 )) && top=0

    printf '\033[H'
    _view_draw "$(printf '\033[1m%s\033[0m' "$title")"
    _view_tabs "$sel" "$cols"; _view_draw "$REPLY"
    _view_draw ""
    local i=$top end=$((top + page))
    while (( i < end && i < lines_count )); do
      _view_draw "${body[$i]}"
      i=$((i + 1))
    done
    printf '\033[J'                      # clear whatever the last frame left below
    _view_keybar "$sel" "$rows" "$cols" "$top" "$lines_count" "$page"

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
  _view_leave "$saved_tty"
  trap - EXIT INT TERM
}

# _view_draw <text>: one row, clearing anything the previous frame left on it.
_view_draw() { printf '%s\033[K\n' "$1"; }

# _view_tabs <sel> <cols>: REPLY = the tab bar, trimmed to one row.
# It keeps the selected worktree visible and marks hidden ones with < and >,
# the way a scrolled list does, instead of wrapping onto more rows.
_view_tabs() {
  local sel="$1" cols="$2" n=${#VIEW_BRANCHES[@]}
  local start="$sel" end=$((sel + 1)) width w grew out=""
  width=$(( ${#VIEW_BRANCHES[$sel]} + 2 ))
  while true; do
    grew=0
    if (( end < n )); then
      w=$(( ${#VIEW_BRANCHES[$end]} + 2 ))
      if (( width + w <= cols - 4 )); then width=$((width + w)); end=$((end + 1)); grew=1; fi
    fi
    if (( start > 0 )); then
      w=$(( ${#VIEW_BRANCHES[$((start - 1))]} + 2 ))
      if (( width + w <= cols - 4 )); then width=$((width + w)); start=$((start - 1)); grew=1; fi
    fi
    (( grew )) || break
  done
  (( start > 0 )) && out+="<"
  local i=$start
  while (( i < end )); do
    if (( i == sel )); then out+=$'\033[7m '"${VIEW_BRANCHES[$i]}"$' \033[0m'
    else                     out+=" ${VIEW_BRANCHES[$i]} "; fi
    i=$((i + 1))
  done
  (( end < n )) && out+=">"
  REPLY="$out"
}

# _view_keybar: the reversed bar on the last row, with position and scroll percent.
_view_keybar() {
  local sel="$1" rows="$2" cols="$3" top="$4" count="$5" page="$6" where
  if (( count <= page )); then where=all
  elif (( top == 0 )); then where=top
  elif (( top >= count - page )); then where=end
  else where="$(( top * 100 / (count - page) ))%"
  fi
  printf '\033[%d;1H\033[7m %-*s\033[0m' "$rows" "$((cols - 1))" \
    "tab/shift-tab worktree   j/k or arrows scroll   space/b page   g/G top/bottom   r reload   q quit  [$((sel + 1))/${#VIEW_BRANCHES[@]}  $where]"
}

# _view_leave: restore everything the viewer may have changed.
_view_leave() {
  local saved_tty="${1:-}"
  (( VIEW_LEFT )) && return
  VIEW_LEFT=1

  printf '\033[?25h\033[?1049l'          # show cursor, leave alternate screen
  _view_mouse_off
  printf '\033[0m'                       # reset SGR attributes/colors

  if [[ -n "$saved_tty" && -t 0 ]]; then
    stty "$saved_tty" 2>/dev/null || stty sane 2>/dev/null || true
  fi
}
