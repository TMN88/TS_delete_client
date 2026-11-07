#!/bin/sh
# OpenWrt / BusyBox ash. Local removal only; no tailnet API calls.
set -u
umask 077

VERSION=1.1.0
YES=0
REBOOT=0
COLOR=auto
COMPONENT=
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
        'sh delete_tailscale.sh [--component NAME] [--yes] [--reboot] [--no-color|--color]' \
        '  --component NAME  podkop|forkop|awg|zapret-manager|zapret2|vpn-failover|site-checker|watchdog|themes' \
        '                  Tailscale доступен отдельно: --component tailscale.' \
        '                  Без флага откроется меню. USB, ttyd и SFTP не включены.' \
        '  --yes       Удалить без интерактивного подтверждения.' \
        '  --reboot    Перезагрузить только после успешной проверки.' \
        '  --no-color  Отключить ANSI-цвета.' \
        '  --color     Включить неоновые ANSI-цвета итогового отчёта.' \
        '  --help      Показать справку.'
}

while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
        --yes|-y) YES=1 ;;
        --reboot) REBOOT=1 ;;
        --component)
            shift
            [ "$#" -gt 0 ] || { printf '%s\n' 'После --component укажи имя компонента.' >&2; usage; exit 2; }
            COMPONENT=$1 ;;
        --component=*) COMPONENT=${arg#*=} ;;
        --no-color) COLOR=off ;;
        --color) COLOR=on ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Неизвестный параметр: %s\n' "$arg" >&2; usage; exit 2 ;;
    esac
    shift
done

if [ -n "$COMPONENT" ]; then
    case "$COMPONENT" in
        podkop|forkop|awg|zapret-manager|zapret2|vpn-failover|site-checker|site-checker2|watchdog|youtube-watchdog|themes|tailscale) ;;
        *) printf 'Неизвестный или исключённый компонент: %s\n' "$COMPONENT" >&2; usage; exit 2 ;;
    esac
fi

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
remove_file() {
    if exists "$1"; then
        if [ -d "$1" ] && [ ! -L "$1" ]; then
            FILES=1; error "Вместо файла обнаружен каталог: $1"; return
        fi
        rm -f "$1" || { FILES=1; error "Не удалось удалить файл: $1"; }
    fi
    if exists "$1"; then FILES=1; error "Файл остался: $1"; fi
}
remove_dir() {
    case "$1" in
        /etc/tailscale|/var/lib/tailscale|/var/run/tailscale|/run/tailscale|/tmp/podkop-vpn-failover|/tmp/podkop-vpn-failover.lock) ;;
        *) FILES=1; error "Недопустимый путь: $1"; return ;;
    esac
    if exists "$1"; then rm -rf "$1" || { FILES=1; error "Не удалось удалить каталог: $1"; }; fi
    if exists "$1"; then FILES=1; error "Каталог остался: $1"; fi
}
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

if [ -z "$COMPONENT" ]; then
    printf '%s\n' \
        'Выбери компонент для удаления:' \
        ' 1. Podkop' \
        ' 2. Forkop' \
        ' 3. AmneziaWG' \
        ' 4. Zapret Manager' \
        ' 5. Zapret2 Routerich' \
        ' 6. VPN Failover' \
        ' 7. Site Checker 2.0' \
        ' 8. YouTube Watchdog' \
        ' 9. Темы LuCI' \
        ' 0. Выход'
    printf 'Номер: '
    IFS= read -r component_choice || component_choice=0
    case "$component_choice" in
        1) COMPONENT=podkop ;; 2) COMPONENT=forkop ;; 3) COMPONENT=awg ;;
        4) COMPONENT=zapret-manager ;; 5) COMPONENT=zapret2 ;; 6) COMPONENT=vpn-failover ;;
        7) COMPONENT=site-checker ;; 8) COMPONENT=watchdog ;; 9) COMPONENT=themes ;;
        0|'') info 'Отменено. Изменения не внесены.'; exit 2 ;;
        *) error 'Неизвестный пункт меню.'; exit 2 ;;
    esac
fi

# Avoid committing any unrelated, previously staged UCI changes.
for cfg in network firewall luci; do
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

remove_package() {
    pkg=$1
    pkg_installed "$pkg" || return 0
    info "Удаляю пакет: $pkg"
    case "$PM" in
        apk) apk del "$pkg" >"$PKG_LOG" 2>&1; result=$? ;;
        opkg) opkg remove "$pkg" >"$PKG_LOG" 2>&1; result=$? ;;
    esac
    if [ "$result" != 0 ] || pkg_installed "$pkg"; then
        PACKAGES=1; error "Не удалось удалить пакет $pkg"
        sed -n '1,25p' "$PKG_LOG" >&2
    fi
}

remove_packages() {
    for pkg do remove_package "$pkg"; done
}

run_component_uninstaller() {
    name=$1; shift
    uninstaller=$1; shift
    if [ ! -x "$uninstaller" ]; then
        error "$name не найден штатный исполняемый деинсталлятор: $uninstaller"
        return 1
    fi
    "$uninstaller" "$@" || { error "Штатное удаление $name завершилось ошибкой."; return 1; }
}

remove_vpn_failover() {
    if [ -x /etc/init.d/podkop-vpn-failover ]; then
        /etc/init.d/podkop-vpn-failover stop >/dev/null 2>&1 || true
        /etc/init.d/podkop-vpn-failover disable >/dev/null 2>&1 || true
    fi
    for path in /www/luci-static/resources/view/vpn-failover.js \
        /usr/libexec/rpcd/vpn-failover /usr/share/luci/menu.d/vpn-failover.json \
        /usr/share/rpcd/acl.d/vpn-failover.json /usr/bin/podkop-vpn-failover \
        /usr/bin/podkop-vpn-failover-control /etc/init.d/podkop-vpn-failover; do
        remove_file "$path"
    done
    remove_dir /tmp/podkop-vpn-failover
    remove_dir /tmp/podkop-vpn-failover.lock
    for section in pvf_history pvf_status pvf_test pvf_logs pvf_config pvf_start pvf_restart pvf_stop; do
        uci -q delete "luci.$section" >/dev/null 2>&1 || true
    done
    uci commit luci >/dev/null 2>&1 || { UCI_RESULT=1; error 'Не удалось сохранить очистку команд VPN Failover из LuCI.'; }
    /etc/init.d/rpcd restart >/dev/null 2>&1 || warn 'Не удалось перезапустить rpcd.'
    info 'Конфигурация /etc/config/vpn_failover и пакет luci-app-commands сохранены.'
}

remove_zapret_manager() {
    command -v ubus >/dev/null 2>&1 || { error 'Не найдена команда ubus для штатного удаления Zapret Manager.'; return 1; }
    info 'Запускаю штатное удаление панели Zapret Manager; установленные движки панели не удаляются.'
    ubus call zapret-manager system_uninstall_panel '{"mode":"wipe"}' >"$PKG_LOG" 2>&1 || {
        error 'Штатное удаление панели Zapret Manager не запустилось.'
        sed -n '1,25p' "$PKG_LOG" >&2
        return 1
    }
    remaining=30
    while [ "$remaining" -gt 0 ] && { exists /opt/zapret-manager-luci/backend.sh || exists /usr/libexec/rpcd/zapret-manager; }; do
        sleep 1; remaining=$((remaining - 1))
    done
    if exists /opt/zapret-manager-luci/backend.sh || exists /usr/libexec/rpcd/zapret-manager; then
        error 'Удаление панели запущено, но её файлы ещё остались; проверь вывод Zapret Manager.'
        return 1
    fi
}

remove_selected_component() {
    case "$COMPONENT" in
        podkop)
            info 'Удаляю интерфейс LuCI и перевод до основного пакета Podkop.'
            # opkg refuses to remove podkop while luci-app-podkop still depends on it.
            remove_packages luci-i18n-podkop-ru luci-app-podkop podkop ;;
        forkop) remove_packages luci-app-forkop forkop ;;
        awg) remove_packages luci-i18n-amneziawg-ru luci-proto-amneziawg luci-app-amneziawg amneziawg-tools kmod-amneziawg ;;
        zapret-manager) remove_zapret_manager || true ;;
        zapret2) remove_packages luci-i18n-zapret2-ru luci-app-zapret2 zapret2 ;;
        vpn-failover) remove_vpn_failover ;;
        site-checker|site-checker2) run_component_uninstaller 'Site Checker 2.0' /usr/libexec/site-checker2-uninstall --yes || true ;;
        watchdog|youtube-watchdog) run_component_uninstaller 'YouTube Watchdog' /usr/libexec/youtube-watchdog-uninstall /etc/config/youtube-watchdog || true ;;
        themes)
            active_theme=$(uci -q get luci.main.mediaurlbase 2>/dev/null || true)
            case "$active_theme" in
                /luci-static/footstrap|/luci-static/argon|/luci-static/aurora)
                    uci set luci.main.mediaurlbase=/luci-static/bootstrap && uci commit luci || {
                        UCI_RESULT=1; error 'Не удалось переключить LuCI на штатную тему; удаление тем остановлено.'; return 1;
                    }
                    info 'Активная сторонняя тема заменена на штатный Bootstrap.' ;;
            esac
            remove_packages luci-theme-footstrap luci-theme-argon luci-theme-aurora luci-app-argon-config ;;
        tailscale) return 0 ;;
    esac
}

if [ "$COMPONENT" != tailscale ]; then
    case "$COMPONENT" in
        podkop) COMPONENT_LABEL=Podkop ;;
        forkop) COMPONENT_LABEL=Forkop ;;
        awg) COMPONENT_LABEL=AmneziaWG ;;
        zapret-manager) COMPONENT_LABEL='Zapret Manager' ;;
        zapret2) COMPONENT_LABEL=Zapret2 ;;
        vpn-failover) COMPONENT_LABEL='VPN Failover' ;;
        site-checker|site-checker2) COMPONENT_LABEL='Site Checker 2.0' ;;
        watchdog|youtube-watchdog) COMPONENT_LABEL='YouTube Watchdog' ;;
        themes) COMPONENT_LABEL='Темы LuCI' ;;
    esac
    info "Удаление компонента: $COMPONENT_LABEL"
    warn 'Общие зависимости пакетный менеджер удаляет сам только если они больше не нужны; принудительное удаление не используется.'
    if [ "$YES" != 1 ]; then
        printf 'Для удаления введи DELETE: '
        read -r answer || answer=
        [ "$answer" = DELETE ] || { info 'Отменено. Изменения не внесены.'; exit 2; }
    fi
    PKG_LOG=$(mktemp /tmp/component-delete.XXXXXX) || { error 'Не удалось создать временный журнал.'; exit 2; }
    remove_selected_component
    if [ "$FAIL" != 0 ]; then
        printf '\n%s  ✗ Удаление %s завершилось с ошибками.%s\n\n' "$RED" "$COMPONENT_LABEL" "$RESET"
        exit 1
    fi
    printf '\n%s  ✓ Удаление %s завершено.%s\n\n' "$GREEN" "$COMPONENT_LABEL" "$RESET"
    if [ "$REBOOT" = 1 ]; then
        info 'Перезагрузка…'
        reboot || { error 'Не удалось выполнить перезагрузку.'; exit 1; }
    fi
    exit 0
fi

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
        printf 'Перезагрузить роутер? [y/n] (по умолчанию y): '
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
    info 'Перезагрузка…'
    reboot || { error 'Не удалось выполнить перезагрузку.'; exit 1; }
else
    info 'Перезагрузка не выполняется.'
    info 'Для проверки после перезагрузки: reboot'
    info 'После загрузки: ip link show tailscale0'
    info 'Ожидаемый результат: Device "tailscale0" does not exist.'
fi

