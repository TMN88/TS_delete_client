#!/bin/sh
# OpenWrt / BusyBox ash. Local removal only; no tailnet API calls.
set -u
umask 077

VERSION=1.0.3
YES=0
REBOOT=0
COLOR=auto
FAIL=0
SERVICE=0
PACKAGES=0
FILES=0
UCI_RESULT=0
NETWORK=0
INTERFACE=0
STARTUP=0
CRON_RESULT=0
NETWORK_CHANGED=0
FIREWALL_CHANGED=0
PKG_LOG=

usage() {
    printf '%s\n' 'TS DELETE CLIENT — OpenWrt' \
        'sh delete_tailscale.sh [--yes] [--reboot] [--no-color|--color]' \
        '  --yes       Удалить без интерактивного подтверждения.' \
        '  --reboot    Перезагрузить только после успешной проверки.' \
        '  --no-color  Отключить ANSI-цвета.' \
        '  --color     Включить неоновые ANSI-цвета итогового отчёта.' \
        '  --help      Показать справку.'
}

for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES=1 ;;
        --reboot) REBOOT=1 ;;
        --no-color) COLOR=off ;;
        --color) COLOR=on ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Неизвестный параметр: %s\n' "$arg" >&2; usage; exit 2 ;;
    esac
done

MAGENTA= GREEN= RED= RESET=
if [ "$COLOR" = on ] || { [ "$COLOR" = auto ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; }; then
    MAGENTA=$(printf '\033[1;95m')
    GREEN=$(printf '\033[1;92m')
    RED=$(printf '\033[1;91m')
    RESET=$(printf '\033[0m')
fi

info() { printf '  › %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
error() { printf '  ✗ %s\n' "$*" >&2; FAIL=1; }
result_error() { printf '%s  ✗ %s%s\n' "$RED" "$*" "$RESET" >&2; FAIL=1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
cleanup() { [ -z "$PKG_LOG" ] || rm -f "$PKG_LOG"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '\n╔══════════════════════════════════════════╗\n'
printf '║           TS DELETE CLIENT               ║\n'
printf '╚══════════════════════════════════════════╝\n'
info "Версия $VERSION · OpenWrt"

[ "$(id -u)" = 0 ] || { error 'Запусти скрипт от root.'; exit 2; }
[ -f /etc/openwrt_release ] || { error 'Поддерживается только OpenWrt.'; exit 2; }
for cmd in uci ip pidof killall awk grep sed rm mktemp sleep; do
    command -v "$cmd" >/dev/null 2>&1 || { error "Не найдена команда: $cmd"; exit 2; }
done
if command -v apk >/dev/null 2>&1; then
    PM=apk
elif command -v opkg >/dev/null 2>&1; then
    PM=opkg
else
    error 'Не найден apk или opkg.'; exit 2
fi

# Avoid committing any unrelated, previously staged UCI changes.
for cfg in network firewall; do
    if ! pending=$(uci -q changes "$cfg"); then
        error "Не удалось проверить изменения UCI: $cfg"; exit 2
    fi
    [ -z "$pending" ] || { error "Есть несохранённые изменения UCI $cfg. Сохрани или отмени их перед запуском."; exit 2; }
done

warn 'Будут удалены Tailscale, его настройки, ключи состояния и локальные файлы.'
warn 'Соединение через Tailscale оборвётся. Запускай через LAN или другой доступ.'
if [ "$YES" != 1 ]; then
    printf 'Для удаления введи DELETE: '
    read -r answer || answer=
    [ "$answer" = DELETE ] || { info 'Отменено. Изменения не внесены.'; exit 2; }
fi
PKG_LOG=$(mktemp /tmp/ts-delete.XXXXXX) || { error 'Не удалось создать временный журнал.'; exit 2; }

info '[1/7] Остановка службы и автозапуска'
# Remove only the exact watcher reported by Zapret Manager. Keep other cron jobs.
WATCHER_MATCH='($1 == "*" && $2 == "*" && $3 == "*" && $4 == "*" && $5 == "*" && $6 == "/opt/zapret-manager-luci/backend.sh" && $7 == "tsc_watch" && $8 == ">/dev/null" && $9 == "2>&1" && $10 == "#" && $11 == "zm-tailscale" && NF == 11)'
if [ -f /etc/crontabs/root ] && awk "$WATCHER_MATCH { found=1 } END { exit !found }" /etc/crontabs/root; then
    info 'Удаляю задание cron zm-tailscale (Zapret Manager: tsc_watch).'
    if ! command -v crontab >/dev/null 2>&1; then
        error 'Не найдена команда crontab. Остановка и удаление отменены.'; exit 1
    fi
    if ! awk "!$WATCHER_MATCH" /etc/crontabs/root >"$PKG_LOG"; then
        error 'Не удалось подготовить cron без tsc_watch. Удаление отменено.'; exit 1
    fi
    if ! crontab "$PKG_LOG"; then
        error 'Не удалось сохранить cron. Остановка и удаление отменены.'; exit 1
    fi
    if awk "$WATCHER_MATCH { found=1 } END { exit !found }" /etc/crontabs/root; then
        error 'Задание tsc_watch осталось в cron. Остановка и удаление отменены.'; exit 1
    fi
fi
for svc in /etc/init.d/tailscale /etc/init.d/tailscaled; do
    if [ -x "$svc" ]; then
        "$svc" disable >/dev/null 2>&1 || warn "Не удалось отключить $svc; проверю оставшиеся ссылки автозапуска."
    fi
done
if command -v tailscale >/dev/null 2>&1; then
    tailscale down >/dev/null 2>&1 || true
fi
for svc in /etc/init.d/tailscale /etc/init.d/tailscaled; do
    if [ -x "$svc" ]; then "$svc" stop >/dev/null 2>&1 || true; fi
done
# Unregister only the two Tailscale service names, preventing procd respawn.
if command -v ubus >/dev/null 2>&1; then
    ubus call service delete '{"name":"tailscale"}' >/dev/null 2>&1 || true
    ubus call service delete '{"name":"tailscaled"}' >/dev/null 2>&1 || true
fi
wait_stopped() {
    remaining=$1
    while pidof tailscaled >/dev/null 2>&1; do
        [ "$remaining" -gt 0 ] || return 1
        sleep 1
        remaining=$((remaining - 1))
    done
    return 0
}
if pidof tailscaled >/dev/null 2>&1; then
    info 'Ожидаю завершения tailscaled после остановки службы (до 10 секунд)…'
    if ! wait_stopped 10; then
        warn 'Отправляю tailscaled SIGTERM и жду до 5 секунд.'
        killall -TERM tailscaled >/dev/null 2>&1 || true
        if ! wait_stopped 5; then
            warn 'Процесс не завершился: отправляю SIGKILL и жду до 5 секунд.'
            killall -KILL tailscaled >/dev/null 2>&1 || true
            wait_stopped 5 || true
        fi
    fi
fi
if pidof tailscaled >/dev/null 2>&1; then
    SERVICE=1; error 'Процесс tailscaled не остановлен. Удаление файлов отменено.'
    warn "Оставшиеся PID: $(pidof tailscaled 2>/dev/null)"
    for proc_id in $(pidof tailscaled 2>/dev/null); do
        case "$proc_id" in ''|*[!0-9]*) continue ;; esac
        if [ -r "/proc/$proc_id/status" ]; then
            awk '/^(Name|State|PPid):/ {print}' "/proc/$proc_id/status"
        fi
    done
    printf '\n%s════════════ РЕЗУЛЬТАТ ════════════%s\n' "$MAGENTA" "$RESET"
    result_error 'Служба не остановлена; пакеты, настройки UCI и файлы не удалялись.'
    warn 'Автозапуск службы уже отключён. Перезагрузка не выполняется.'
    exit 1
fi

info '[2/7] Удаление настроек UCI'
for cfg in network firewall; do
    if uci -q get "$cfg.tailscale" >/dev/null 2>&1; then
        if uci -q delete "$cfg.tailscale" && uci commit "$cfg"; then
            case "$cfg" in network) NETWORK_CHANGED=1 ;; firewall) FIREWALL_CHANGED=1 ;; esac
        else
            UCI_RESULT=1; error "Не удалось удалить/сохранить $cfg.tailscale"
        fi
    fi
done

pkg_installed() {
    case "$PM" in
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
        opkg) opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed$' ;;
    esac
}

info "[3/7] Удаление пакетов через $PM"
# Remove optional front ends before their dependencies. Never force dependencies.
for pkg in luci-app-tailscale-community luci-app-tailscale tailscale tailscaled; do
    if pkg_installed "$pkg"; then
        info "Удаляю пакет: $pkg"
        case "$PM" in
            apk) apk del "$pkg" >"$PKG_LOG" 2>&1; result=$? ;;
            opkg) opkg remove "$pkg" >"$PKG_LOG" 2>&1; result=$? ;;
        esac
        if [ "$result" != 0 ] || pkg_installed "$pkg"; then
            PACKAGES=1; error "Не удалось удалить пакет $pkg"
            sed -n '1,25p' "$PKG_LOG" >&2
        fi
    fi
done

remove_file() {
    if exists "$1"; then
        # Do not recursively erase unexpected directories in file locations.
        if [ -d "$1" ] && [ ! -L "$1" ]; then
            FILES=1; error "Вместо файла обнаружен каталог: $1"; return
        fi
        rm -f "$1" || { FILES=1; error "Не удалось удалить файл: $1"; }
    fi
    if exists "$1"; then FILES=1; error "Файл остался: $1"; fi
}

remove_dir() {
    # Only these dedicated, literal directories can be recursively removed.
    case "$1" in
        /etc/tailscale|/var/lib/tailscale|/var/run/tailscale|/run/tailscale) ;;
        *) FILES=1; error "Недопустимый путь: $1"; return ;;
    esac
    if exists "$1"; then
        rm -rf "$1" || { FILES=1; error "Не удалось удалить каталог: $1"; }
    fi
    if exists "$1"; then FILES=1; error "Каталог остался: $1"; fi
}

info '[4/7] Удаление файлов и ключей состояния'
remove_file /etc/hotplug.d/iface/95-tailscale
for path in /etc/rc.d/*tailscale /etc/rc.d/*tailscaled; do
    exists "$path" && remove_file "$path"
done
for path in /etc/config/tailscale /etc/config/tailscale-opkg /etc/config/tailscale.apk-save \
    /etc/config/tailscale.apk-new /etc/config/tailscaled; do
    remove_file "$path"
done
for path in /etc/tailscale /var/lib/tailscale /var/run/tailscale /run/tailscale; do
    remove_dir "$path"
done
remove_file /var/run/tailscaled.sock
remove_file /var/run/tailscaled.pid
# Only delete orphan executables/service scripts once all packages were removed.
if [ "$PACKAGES" = 0 ]; then
    for path in /etc/init.d/tailscale /etc/init.d/tailscaled \
        /usr/bin/tailscale /usr/sbin/tailscale /usr/bin/tailscaled /usr/sbin/tailscaled; do
        remove_file "$path"
    done
else
    FILES=1
    warn 'Исполняемые файлы и init-скрипты сохранены: пакетный менеджер не завершил удаление.'
fi

info '[5/7] Применение настроек сети'
if [ "$NETWORK_CHANGED" = 1 ]; then
    /etc/init.d/network reload || { NETWORK=1; error 'Не удалось применить настройки сети.'; }
fi
if [ "$FIREWALL_CHANGED" = 1 ]; then
    /etc/init.d/firewall restart || { NETWORK=1; error 'Не удалось перезапустить firewall.'; }
fi
if ip link show tailscale0 >/dev/null 2>&1; then
    ip link delete tailscale0 >/dev/null 2>&1 || true
fi

info '[6/7] Проверка ручного автозапуска'
# Report custom scripts rather than deleting whole shared startup files.
for path in /etc/rc.local /etc/crontabs/* /etc/hotplug.d/iface/*; do
    [ -f "$path" ] || continue
    if grep -v '^[[:space:]]*#' "$path" | grep -Eq '(^|[^[:alnum:]_])tailscale(d)?([^[:alnum:]_]|$)'; then
        STARTUP=1; error "Осталась ссылка на Tailscale в ручном автозапуске: $path"
    fi
done

info '[7/7] Итоговая проверка'
for pkg in luci-app-tailscale-community luci-app-tailscale tailscale tailscaled; do
    if pkg_installed "$pkg"; then PACKAGES=1; error "Пакет всё ещё установлен: $pkg"; fi
done
if pidof tailscaled >/dev/null 2>&1; then SERVICE=1; error 'Процесс tailscaled запущен.'; fi
for cfg in network firewall; do
    if uci -q get "$cfg.tailscale" >/dev/null 2>&1; then
        UCI_RESULT=1; error "Секция $cfg.tailscale осталась."
    fi
done
if ip link show tailscale0 >/dev/null 2>&1; then
    INTERFACE=1; error 'Интерфейс tailscale0 остался.'
fi
hash -r 2>/dev/null || true
for cmd in tailscale tailscaled; do
    if command -v "$cmd" >/dev/null 2>&1; then
        FILES=1; error "Команда $cmd всё ещё доступна; возможна ручная установка или файл в прошивке."
    fi
done

row() {
    if [ "$1" = 0 ]; then
        printf '%s  ✓ %s%s\n' "$GREEN" "$2" "$RESET"
    else
        printf '%s  ✗ %s%s\n' "$RED" "$3" "$RESET"
    fi
}
printf '\n%s════════════ РЕЗУЛЬТАТ ════════════%s\n' "$MAGENTA" "$RESET"
row "$SERVICE" 'Служба остановлена' 'Служба не остановлена'
row "$PACKAGES" 'Пакет Tailscale и установленные LuCI-модули удалены / отсутствуют' 'Не все пакеты удалены'
row "$FILES" 'Файлы, конфигурация и ключи состояния удалены / отсутствуют' 'Не все файлы удалены'
row "$UCI_RESULT" 'Секции network.tailscale и firewall.tailscale удалены / отсутствуют' 'Ошибка удаления настроек UCI'
row "$NETWORK" 'Изменения сети применены / не требовались' 'Ошибка применения сети'
row "$INTERFACE" 'Интерфейс tailscale0 отсутствует' 'Интерфейс tailscale0 остался'
if [ -f /etc/crontabs/root ] && awk "$WATCHER_MATCH { found=1 } END { exit !found }" /etc/crontabs/root; then
    CRON_RESULT=1; FAIL=1
fi
row "$CRON_RESULT" 'Задание cron zm-tailscale (tsc_watch) удалено / отсутствует' 'Задание cron zm-tailscale осталось'
row "$STARTUP" 'Ссылки на Tailscale в проверенном ручном автозапуске не найдены' 'Остались ссылки в ручном автозапуске — см. пути выше'
if [ "$FAIL" != 0 ]; then
    result_error 'Удаление завершено с ошибками. Автоматическая перезагрузка отменена.'
    exit 1
fi
printf '%s  ✓ УДАЛЕНИЕ ЗАВЕРШЕНО%s\n\n' "$GREEN" "$RESET"
if [ "$REBOOT" != 1 ] && [ -t 0 ]; then
    while :; do
        printf 'Перезагрузить роутер? [Y/n]: '
        if ! read -r reboot_answer; then
            info 'Ввод недоступен. Перезагрузка не выполняется.'
            break
        fi
        case "$reboot_answer" in
            ''|y|Y|yes|YES|Yes|д|Д|да|Да|ДА) REBOOT=1; break ;;
            n|N|no|NO|No|н|Н|нет|Нет|НЕТ) break ;;
            *) info 'Нажми Enter для перезагрузки или введи n для отказа.' ;;
        esac
    done
fi
if [ "$REBOOT" = 1 ]; then
    warn 'Перезагрузка через 5 секунд…'
    sleep 5
    reboot || { error 'Не удалось выполнить перезагрузку.'; exit 1; }
else
    info 'Перезагрузка не выполняется.'
    info 'Для проверки после перезагрузки: reboot'
    info 'После загрузки: ip link show tailscale0'
    info 'Ожидаемый результат: Device "tailscale0" does not exist.'
fi
