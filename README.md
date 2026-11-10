# TS_delete_client / OpenWrt component cleanup

Скрипт удаляет выбранные компоненты OpenWrt: Podkop, Forkop, AmneziaWG, Zapret Manager, Zapret2 Routerich, VPN Failover, Site Checker 2.0, YouTube Watchdog или сторонние темы LuCI.

**Tailscale этим скриптом удалить или отключить невозможно.** Его выбор явно отклоняется с кодом 2. Во всех остальных вариантах скрипт не останавливает службу Tailscale, не вызывает `tailscale down`, не меняет его UCI-настройки и не удаляет его пакеты или файлы. Имя `delete_tailscale.sh` оставлено ради совместимости со старой командой.

## Запуск

Скрипт покажет меню, а `--yes` пропустит подтверждение удаления, сохранив меню:

```sh
wget -O /tmp/delete_tailscale.sh https://raw.githubusercontent.com/TMN88/TS_delete_client/main/delete_tailscale.sh && sh /tmp/delete_tailscale.sh --yes --color
```

Чтобы удалить компонент напрямую, укажи его имя, например:

```sh
sh /tmp/delete_tailscale.sh --component podkop --yes
```

Поддерживаются `podkop`, `forkop`, `awg`, `zapret-manager`, `zapret2`, `vpn-failover`, `site-checker`, `watchdog`, `themes`. Терминал `ttyd`, USB-модули и SFTP-сервер исключены. Параметр `--reboot` перезагружает роутер только после успешного удаления.

## Как удаляются компоненты

- **Podkop:** LuCI-перевод, `luci-app-podkop`, затем `podkop`. Принудительное удаление зависимостей не используется.
- **Forkop, AmneziaWG и Zapret2 Routerich:** известные пакеты удаляются штатным пакетным менеджером.
- **Zapret Manager:** вызывается штатное удаление панели.
- **VPN Failover:** удаляются его служба и файлы страницы; конфигурация `vpn_failover` и общий пакет `luci-app-commands` сохраняются.
- **Site Checker 2.0 и YouTube Watchdog:** запускаются их штатные деинсталляторы.
- **Темы LuCI:** удаляются Footstrap, Argon и Aurora; перед этим активная тема переключается на Bootstrap.

Скрипт работает в POSIX `sh` / BusyBox `ash` с `opkg` или `apk`. Несохранённые изменения UCI `network`, `firewall` или `luci` блокируют запуск, чтобы не сохранить посторонние изменения. Сначала проверь, что у тебя есть независимый доступ к роутеру, если удаляемый компонент нужен для управления.

## Проверка

Версия 1.2.0 проверяется локальными сценариями с подставными командами, включая все девять пунктов меню и отказ на прямой запрос удалить Tailscale. На настоящем роутере эта версия не запускалась.

