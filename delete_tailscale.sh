#!/bin/sh
# OpenWrt / BusyBox ash. Removes selected toolkit components; never removes Tailscale.
set -u
umask 077

VERSION=1.2.0
YES=0
REBOOT=0
COLOR=auto
COMPONENT=
FAIL=0
PACKAGES=0
FILES=0
UCI_RESULT=0
PKG_LOG=

usage() {
    printf '%s\n' 'OPENWRT COMPONENT CLEANUP' \
        'sh delete_tailscale.sh [--component NAME] [--yes] [--reboot] [--no-color|--color]' \
        '  --component NAME  podkop|forkop|awg|zapret-manager|zapret2|vpn-failover|site-checker|watchdog|themes' \
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
        podkop|forkop|awg|zapret-manager|zapret2|vpn-failover|site-checker|site-checker2|watchdog|youtube-watchdog|themes) ;;
        tailscale|tailscaled) printf '%s\n' 'Удаление Tailscale этим скриптом отключено.' >&2; exit 2 ;;
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
        /tmp/podkop-vpn-failover|/tmp/podkop-vpn-failover.lock) ;;
        *) FILES=1; error "Недопустимый путь: $1"; return ;;
    esac
    if exists "$1"; then rm -rf "$1" || { FILES=1; error "Не удалось удалить каталог: $1"; }; fi
    if exists "$1"; then FILES=1; error "Каталог остался: $1"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '\n╔══════════════════════════════════════════╗\n'
printf '║      OPENWRT COMPONENT CLEANUP            ║\n'
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

pkg_installed() {
    case "$PM" in
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
        opkg) opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed$' ;;
    esac
}

remove_package() {
    pkg=$1
    case "$pkg" in
        tailscale*|luci-app-tailscale*|luci-i18n-tailscale*)
            error "Защитный запрет: пакет Tailscale нельзя удалять этим скриптом: $pkg"
            return 1 ;;
    esac
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
    esac
}

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

