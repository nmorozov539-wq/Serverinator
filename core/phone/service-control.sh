# shellcheck shell=bash
# ServerInator Core, phone side: start, stop, restart (si start|stop|restart)
# Sourced by core-phone.sh, which holds the settings and globals used here.

# ── Start / stop (si start|stop|restart) ──────

# NAME -> "SCRIPT CHILD_PIDFILE" (the child pid file is empty for wireguard,
# whose supervisor runs short commands). Order: the order they start in.
CONTROL_SERVICES="wstunnel wireguard sshd tmpclean"
service_parts() { # NAME
    case "$1" in
        wstunnel)  echo "$MAGISK_SERVICE_D/10-serverinator-wstunnel.sh wstunnel.pid" ;;
        wireguard) echo "$MAGISK_SERVICE_D/20-serverinator-wireguard.sh -" ;;
        sshd)      echo "$MAGISK_SERVICE_D/30-serverinator-sshd.sh sshd.pid" ;;
        tmpclean)  echo "$MAGISK_SERVICE_D/40-serverinator-tmpclean.sh -" ;;
        *) die "Unknown service: $1 (one of: $CONTROL_SERVICES)" ;;
    esac
}

stop_service() { # NAME
    local script child pid root
    read -r script child <<< "$(service_parts "$1")"
    if status_pid_alive "$STATE_DIR/run/$1-supervisor.pid"; then
        read -r pid < "$STATE_DIR/run/$1-supervisor.pid"
        # A supervisor that died leaves its pid file behind, and Android
        # reuses pids fast: then it's not ours, and nothing is killed. (Seen
        # on rn9p: a restart stopped at such a file and left sshd down.)
        if tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fxq -e "$script" -e "${script}.bak"; then
            stop_exact_pid "$pid" "$script" supervisor
        else
            warn "$1: its pid file is stale (pid $pid is something else now); left that alone"
        fi
    fi
    # The supervisor stops its child on TERM, but a KILL skips that.
    if [[ "$child" != - ]] && status_pid_alive "$STATE_DIR/run/$child"; then
        read -r pid < "$STATE_DIR/run/$child"
        root="$(readlink "/proc/$pid/root" 2>/dev/null)" || root=""
        if [[ "$root" == "$CHROOT" ]]; then stop_exact_pid "$pid" "$CHROOT" child; fi
    fi
    rm -f "$STATE_DIR/run/$1-supervisor.pid"
    [[ "$child" == - ]] || rm -f "$STATE_DIR/run/$child"
}

start_service() { # NAME -> 0 started, 1 already running, 2 not installed
    local script child
    read -r script child <<< "$(service_parts "$1")"
    [[ -f "$script" ]] || return 2
    status_pid_alive "$STATE_DIR/run/$1-supervisor.pid" && return 1
    # Detached like Magisk does at boot, so it outlives this shell.
    if have_cmd setsid; then
        setsid sh "$script" < /dev/null > /dev/null 2>&1 &
    else
        nohup sh "$script" < /dev/null > /dev/null 2>&1 &
    fi
    return 0
}

# What a reboot did: (re)start the boot scripts, without the reboot.
control_services() { # start|stop|restart [NAME]
    local action="$1" names="${2:-$CONTROL_SERVICES}" name rc script _
    check_root
    [[ -f "$CHROOT/etc/wireguard/wg-si.conf" ]] || die "Core is not installed on this phone"
    for name in $names; do service_parts "$name" > /dev/null; done
    if [[ "$action" != start ]]; then
        local reversed=""
        for name in $names; do reversed="$name $reversed"; done
        for name in $reversed; do
            read -r script _ <<< "$(service_parts "$name")"
            [[ -f "$script" || -n "${2:-}" ]] || continue
            stop_service "$name"; info "$name stopped"
        done
    fi
    [[ "$action" != stop ]] || return 0
    sh "$MAGISK_SERVICE_D/00-serverinator-mount.sh" || die "The chroot mount script failed"
    for name in $names; do
        rc=0; start_service "$name" || rc=$?
        case "$rc" in
            0) ok "$name started" ;;
            1) info "$name was already running" ;;
            2) [[ -n "${2:-}" ]] && warn "$name isn't installed" ;;
        esac
    done
    echo "  The tunnel comes up within seconds once the network is there: si status"
}
