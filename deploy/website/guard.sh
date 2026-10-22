#!/bin/sh
set -eu

site=/home/233/apps/miku-desktop-site
exec 9>"$site/run/guard.lock"
/usr/bin/flock -n 9 || exit 0

if [ -s "$site/run/nginx.pid" ]; then
    pid=$(cat "$site/run/nginx.pid")
    case "$pid" in
        ''|*[!0-9]*) exit 1 ;;
    esac
    if kill -0 "$pid" 2>/dev/null; then
        command=$(ps -p "$pid" -o args=)
        case "$command" in
            "nginx: master process /usr/sbin/nginx -p $site/ -c $site/nginx.conf") exit 0 ;;
            *) exit 1 ;;
        esac
    fi
fi

/usr/sbin/nginx -t -q -p "$site/" -c "$site/nginx.conf"
/usr/sbin/nginx -p "$site/" -c "$site/nginx.conf" 9>&-
