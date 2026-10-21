#!/usr/bin/env bash
# ==========================================================
#  LAN SSH local forward: reach a loopback-only service on another host
#
#  客户端: 浏览器 → http://127.0.0.2:<P>
#  隧道:   ssh -N -L 127.0.0.2:<P>:127.0.0.1:<P> <ssh-alias>
#  服务端: 服务只监听 127.0.0.1:<P>（永远不放开 0.0.0.0）
#
#  Usage:
#      forward.sh start  --ssh <alias|user@host> --service <port|host:port>
#                        [--peer <ip>] [--local <ip:port>] [--name <tag>]
#                        [--check <regex>] [--port <sshd-port>] [--open]
#      forward.sh stop    [--name <tag>]
#      forward.sh status  [--name <tag>]
# ==========================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNDIR="$SCRIPT_DIR/.run"
mkdir -p "$RUNDIR" 2>/dev/null

say() { printf '%s\n' "$*"; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

[ $# -ge 1 ] || usage
CMD="$1"; shift

SSH_HOST=""; PEER=""; SERVICE=""; LOCAL=""; NAME=""; CHECK=""; SSH_PORT=""; OPEN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh)     SSH_HOST="${2:-}"; shift 2 ;;
    --peer)    PEER="${2:-}"; shift 2 ;;
    --service) SERVICE="${2:-}"; shift 2 ;;
    --local)   LOCAL="${2:-}"; shift 2 ;;
    --name)    NAME="${2:-}"; shift 2 ;;
    --check)   CHECK="${2:-}"; shift 2 ;;
    --port)    SSH_PORT="${2:-}"; shift 2 ;;
    --open)    OPEN=1; shift ;;
    -h|--help) usage 0 ;;
    *)         say "unknown option: $1"; usage ;;
  esac
done

# honour the ssh config's Port (phones often use 8022, not 22)
if [ -z "$SSH_PORT" ]; then
  SSH_PORT="$(ssh -G "$SSH_HOST" 2>/dev/null | awk 'tolower($1)=="port"{print $2; exit}')"
  SSH_PORT="${SSH_PORT:-22}"
fi

PLATFORM=linux
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  Darwin)               PLATFORM=macos ;;
esac

# ---------- service address ----------
if [ -n "$SERVICE" ]; then
  case "$SERVICE" in
    *:*) SVC_HOST="${SERVICE%%:*}"; SVC_PORT="${SERVICE##*:}" ;;
    *)   SVC_HOST="127.0.0.1";     SVC_PORT="$SERVICE" ;;
  esac
fi

NAME="${NAME:-}"
if [ -z "$NAME" ] && [ -n "$SSH_HOST" ] && [ -n "${SVC_PORT:-}" ]; then
  NAME="$(printf '%s' "$SSH_HOST" | tr -c 'A-Za-z0-9_.-' '_')-${SVC_PORT}"
fi
[ -n "$NAME" ] || NAME="default"

PIDFILE="$RUNDIR/$NAME.pid"
TUNLOG="$RUNDIR/$NAME.log"
LOCKDIR="$RUNDIR/.lock-$NAME"

# ---------- Windows reserved port ranges ----------
port_excluded() {
  [ "$PLATFORM" = windows ] || return 1
  netsh int ipv4 show excludedportrange protocol=tcp 2>/dev/null | awk -v p="$1" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && p + 0 >= $1 + 0 && p + 0 <= $2 + 0 { hit = 1 }
    END { exit hit ? 0 : 1 }'
}

port_listening() {
  [ "$PLATFORM" = windows ] || return 1
  netstat -ano -p tcp 2>/dev/null | awk -v p=":$1" '
    $1 == "TCP" && $4 == "LISTENING" && index($2, p) { sub(/:[0-9]+$/, "", $2); print $2 }' | grep -Fqx "$2"
}

tcp_ok() {
  (exec 3<>"/dev/tcp/$1/$2") >/dev/null 2>&1
}

# A plain TCP connect is not proof: carrier/hotspot middleboxes happily accept
# SYNs to any address. Only a real sshd sends an SSH-2.0 banner.
ssh_banner_ok() {
  ( exec 3<>"/dev/tcp/$1/$2" || exit 1
    IFS= read -r -t 4 banner <&3 || exit 1
    case "$banner" in SSH-2.0-*|SSH-1.99-*) exit 0 ;; *) exit 1 ;; esac
  ) 2>/dev/null
}

open_url() {
  case "$PLATFORM" in
    windows) cmd.exe /c start "" "$1" >/dev/null 2>&1 ;;
    macos)   open "$1" >/dev/null 2>&1 ;;
    *)       xdg-open "$1" >/dev/null 2>&1 ;;
  esac
}

# ---------- peer address discovery ----------
resolve_peer() {
  if [ -n "$PEER" ]; then
    printf '%s' "$PEER"
    return 0
  fi
  if [ -n "$SSH_HOST" ]; then
    local configured
    configured="$(ssh -G "$SSH_HOST" 2>/dev/null | awk 'tolower($1)=="hostname"{print $2; exit}')"
    case "$configured" in
      ""|"%h") ;;
      *)
        case "$configured" in
          *[!0-9.]*) ;;   # a DNS name: the OS resolver handles it, no need to pin
          *) if ssh_banner_ok "$configured" "$SSH_PORT"; then printf '%s' "$configured"; return 0; fi ;;
        esac ;;
    esac
  fi
  case "$PLATFORM" in
    windows)
      local ps1="$SCRIPT_DIR/peer-ip.ps1"
      if [ -f "$ps1" ]; then
        local win; win="$(cygpath -w "$ps1" 2>/dev/null || printf '%s' "$ps1")"
        local ip
        ip=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
             -File "$win" -SshHost "$SSH_HOST" -SshPort "$SSH_PORT" 2>/dev/null | tr -d '\r' | head -1)
        [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
      fi ;;
    macos)
      local gw; gw=$(ipconfig getoption en0 router 2>/dev/null)
      [ -n "$gw" ] && ssh_banner_ok "$gw" "$SSH_PORT" && { printf '%s' "$gw"; return 0; } ;;
    *)
      local gw
      gw=$(ip route show default dev wlan0 2>/dev/null | awk '{print $3; exit}')
      [ -z "$gw" ] && gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
      [ -n "$gw" ] && ssh_banner_ok "$gw" "$SSH_PORT" && { printf '%s' "$gw"; return 0; } ;;
  esac
  return 1
}

ssh_opts() {
  local out="-o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ConnectTimeout=10"
  out="$out -o ExitOnForwardFailure=yes -o BatchMode=yes -p $SSH_PORT"
  [ -n "$RESOLVED_PEER" ] && out="$out -o HostName=$RESOLVED_PEER"
  printf '%s' "$out"
}

url_for() {
  printf 'http://%s:%s/' "$1" "$2"
}

check_content() {
  [ -n "$CHECK" ] || return 0
  curl -s -m 8 --noproxy '*' "$(url_for "$LOCAL_HOST" "$LOCAL_PORT")" 2>/dev/null | grep -qE "$CHECK"
}

wait_ready() {
  local i
  for i in $(seq 1 15); do
    sleep 1
    tcp_ok "$LOCAL_HOST" "$LOCAL_PORT" || continue
    if check_content; then return 0; fi
    [ -z "$CHECK" ] && return 0
  done
  return 1
}

# ---------- commands ----------
do_start() {
  [ -n "$SSH_HOST" ] && [ -n "${SVC_PORT:-}" ] || { say "start needs --ssh and --service"; exit 2; }

  if [ -n "$LOCAL" ]; then
    LOCAL_HOST="${LOCAL%%:*}"; LOCAL_PORT="${LOCAL##*:}"
    [ "$LOCAL_PORT" = "$LOCAL" ] && LOCAL_PORT="$SVC_PORT"
  else
    LOCAL_HOST="127.0.0.2"; LOCAL_PORT="$SVC_PORT"
  fi
  printf '%s %s %s %s\n' "$LOCAL_HOST" "$LOCAL_PORT" "$SVC_HOST" "$SVC_PORT" > "$RUNDIR/$NAME.state" 2>/dev/null

  # port hygiene: reserved ranges / foreign listeners
  if port_excluded "$LOCAL_PORT"; then
    say "!! local port $LOCAL_PORT is in a Windows reserved range (bind always denied)"
    [ -n "$LOCAL" ] && { say "   pick another: --local $LOCAL_HOST:<other>"; exit 1; }
    local cand="$((LOCAL_PORT + 1000))"
    say "   retrying with $cand"
    LOCAL_PORT="$cand"
  fi
  if [ "$PLATFORM" = windows ] && port_listening "$LOCAL_PORT" "$LOCAL_HOST"; then
    say "!! $LOCAL_HOST:$LOCAL_PORT is already listening"
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
      say "   it is our tunnel ($NAME); reuse it"
      print_ready
      return 0
    fi
    say "   another process holds it; use --local $LOCAL_HOST:<other> or stop it"
    exit 1
  fi

  # single instance
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    say "!! another forward.sh --name $NAME is running"
    exit 1
  fi
  trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT

  if [ -f "$PIDFILE" ]; then
    local old; old=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "${old:-}" ] && kill "$old" 2>/dev/null && sleep 1
    rm -f "$PIDFILE"
  fi

  RESOLVED_PEER="$(resolve_peer)" || {
    say "!! cannot determine the peer address"
    say "   pass --peer <ip>, or make sure ~/.ssh/config Host $SSH_HOST has a usable HostName"
    exit 1
  }
  [ -n "$RESOLVED_PEER" ] || say "   (peer address comes from ssh config / DNS)"

  say ">>> ssh $SSH_HOST${RESOLVED_PEER:+ ($RESOLVED_PEER)} ..."
  if ! ssh $(ssh_opts) "$SSH_HOST" 'true' 2>/dev/null; then
    say "!! ssh failed; check host/port/key (this script never prompts)"
    exit 1
  fi
  say ">>> ssh ok"

  say ">>> forwarding $LOCAL_HOST:$LOCAL_PORT -> $SSH_HOST:$SVC_HOST:$SVC_PORT"
  : > "$TUNLOG"
  nohup ssh -N -L "$LOCAL_HOST:$LOCAL_PORT:$SVC_HOST:$SVC_PORT" $(ssh_opts) \
        "$SSH_HOST" >>"$TUNLOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$PIDFILE" 2>/dev/null || true
  disown 2>/dev/null || true

  if wait_ready; then
    print_ready
  else
    say "!! tunnel did not become ready"
    sed 's/^/   /' "$TUNLOG" 2>/dev/null
    grep -qiE 'bind \[|cannot listen' "$TUNLOG" 2>/dev/null && \
      say "   hint: port busy or reserved; try --local $LOCAL_HOST:<other>"
    exit 1
  fi
}

print_ready() {
  local url; url="$(url_for "$LOCAL_HOST" "$LOCAL_PORT")"
  say ""
  say "============================================================"
  say "  browser / client:  $url"
  [ -n "$CHECK" ] && say "  verified:          matches /$CHECK/"
  say "  tunnel pid:        $(cat "$PIDFILE" 2>/dev/null)"
  say "  stop:              $0 stop --name $NAME"
  say "============================================================"
  if [ "$OPEN" = 1 ]; then open_url "$url"; fi
  return 0
}

do_stop() {
  if [ -f "$PIDFILE" ]; then
    local pid; pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null; then
      say "stopped $NAME (pid $pid)"
    else
      say "$NAME has no live process"
    fi
    rm -f "$PIDFILE"
  else
    say "no pidfile for $NAME"
  fi
  rm -f "$RUNDIR/$NAME.state" 2>/dev/null
  rm -rf "$LOCKDIR" 2>/dev/null
}

do_status() {
  local pid="" state=""
  [ -f "$PIDFILE" ] && pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -f "$RUNDIR/$NAME.state" ] && state=$(cat "$RUNDIR/$NAME.state" 2>/dev/null)
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    say "$NAME: running (pid $pid)"
    if [ -n "$state" ]; then
      set -- $state
      say "  local:  http://$1:$2/"
      say "  remote: $3:$4 via ssh"
      if tcp_ok "$1" "$2"; then say "  probe:  tcp ok"; else say "  probe:  tcp failed"; fi
    fi
    return 0
  fi
  say "$NAME: not running"
  return 1
}

case "$CMD" in
  start)  do_start ;;
  stop)   do_stop ;;
  status) do_status ;;
  *)      usage ;;
esac
