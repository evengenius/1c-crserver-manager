#!/bin/bash
set -euo pipefail

# ============================================================================
#  crserver-manager.sh — Управление сервером хранилища конфигураций 1С
#  Debian 12 / Ubuntu 22.04+
#
#  Использование:
#    sudo ./crserver-manager.sh              — интерактивное меню
#    sudo ./crserver-manager.sh install      — установка
#    sudo ./crserver-manager.sh status       — статус
#    sudo ./crserver-manager.sh help         — справка
#
#  Структура каталога пакетов (packages/ рядом со скриптом):
#    packages/
#    ├── 8.3.25.1560/
#    │   ├── 1c-enterprise-8.3.25.1560-common_*.deb
#    │   ├── 1c-enterprise-8.3.25.1560-server_*.deb
#    │   ├── 1c-enterprise-8.3.25.1560-ws_*.deb
#    │   └── 1c-enterprise-8.3.25.1560-crs_*.deb
#    ├── 8.3.26.XXXX/
#    │   └── ...
# ============================================================================

# --- Версия скрипта ---
# При выпуске новой версии увеличить и закоммитить в репозиторий.
# Используется для проверки обновлений (см. do_self_update).
SCRIPT_VERSION="1.4.0"

# --- Источник обновлений ---
UPDATE_REPO="evengenius/1c-crserver-manager"
UPDATE_BRANCH="main"
UPDATE_URL="https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}/crserver-manager.sh"

# --- Конфигурация ---
CONFIG_FILE="/etc/1c-crserver/crserver.conf"
DEFAULT_REPO_DIR="/var/1c/repo"
DEFAULT_REPO_PORT=1542
DEFAULT_LOG_DIR="/var/log/1c/crserver"
DEFAULT_BACKUP_DIR="/var/1c/backup"
SERVICE_NAME="crserver"
IPTABLES_CHAIN="CRSERVER"
PACKAGES_DIR_NAME="packages"

# --- Пути (вычисляются при запуске) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="${SCRIPT_DIR}/${PACKAGES_DIR_NAME}"

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Логирование ---
log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${CYAN}[→]${NC} $1"; }

# --- Проверка root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Запустите скрипт от root: sudo $0"
        exit 1
    fi
}

# ============================================================================
#  КОНФИГУРАЦИЯ
# ============================================================================

load_config() {
    # Сбрасываем переменные, чтобы повторный вызов с пустым/изменённым конфигом
    # не сохранял старые значения
    REPO_DIR=""; REPO_PORT=""; LOG_DIR=""; BACKUP_DIR=""

    # Безопасный парсинг: только KEY="VALUE" из белого списка ключей
    if [[ -f "$CONFIG_FILE" ]]; then
        local line key val
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Пропуск комментариев/пустых
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line//[[:space:]]/}" ]] && continue
            # Формат KEY="value" или KEY=value (без подстановок)
            if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=\"?([^\"]*)\"?[[:space:]]*$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                case "$key" in
                    REPO_DIR|REPO_PORT|LOG_DIR|BACKUP_DIR)
                        printf -v "$key" '%s' "$val"
                        ;;
                esac
            fi
        done < "$CONFIG_FILE"
    fi

    REPO_DIR="${REPO_DIR:-$DEFAULT_REPO_DIR}"
    REPO_PORT="${REPO_PORT:-$DEFAULT_REPO_PORT}"
    LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
    BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# Конфигурация сервера хранилища 1С
REPO_DIR="$REPO_DIR"
REPO_PORT="$REPO_PORT"
LOG_DIR="$LOG_DIR"
BACKUP_DIR="$BACKUP_DIR"
EOF
    log_info "Конфигурация сохранена: $CONFIG_FILE"
}

# ============================================================================
#  ОПРЕДЕЛЕНИЕ ПЛАТФОРМЫ И ВЕРСИЙ
# ============================================================================

# Определяет активную версию (из systemd-службы).
# Выставляет:
#   ACTIVE_VERSION         — строка версии "8.3.X.Y" или ""
#   ACTIVE_CRSERVER_BIN    — путь к бинарнику из ExecStart
#   ACTIVE_VERSION_PHANTOM — 1 если в юните указана версия, бинарника которой нет
detect_active_version() {
    ACTIVE_VERSION=""
    ACTIVE_CRSERVER_BIN=""
    ACTIVE_VERSION_PHANTOM=0

    if [[ -f /etc/systemd/system/${SERVICE_NAME}.service ]]; then
        local exec_line
        exec_line=$(grep "^ExecStart=" /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || true)
        if [[ -n "$exec_line" ]]; then
            ACTIVE_CRSERVER_BIN=$(echo "$exec_line" | sed 's/^ExecStart=//' | awk '{print $1}')
            ACTIVE_VERSION=$(echo "$ACTIVE_CRSERVER_BIN" | grep -oP '8\.3\.\d+\.\d+' || true)
            # Фантом: юнит ссылается на удалённый бинарник
            if [[ -n "$ACTIVE_CRSERVER_BIN" && ! -f "$ACTIVE_CRSERVER_BIN" ]]; then
                ACTIVE_VERSION_PHANTOM=1
            fi
        fi
    fi

    # Фоллбэк: ищем любой установленный crserver
    if [[ -z "$ACTIVE_VERSION" ]] && [[ -d /opt/1cv8/x86_64 ]]; then
        for dir in /opt/1cv8/x86_64/*/; do
            if [[ -f "${dir}crserver" ]]; then
                ACTIVE_CRSERVER_BIN="${dir}crserver"
                ACTIVE_VERSION=$(basename "$dir")
                ACTIVE_VERSION_PHANTOM=0
                break
            fi
        done
    fi
}

# Возвращает массив установленных версий (у которых есть crserver)
get_installed_versions() {
    INSTALLED_VERSIONS=()
    if [[ -d /opt/1cv8/x86_64 ]]; then
        for dir in /opt/1cv8/x86_64/*/; do
            if [[ -f "${dir}crserver" ]]; then
                INSTALLED_VERSIONS+=("$(basename "$dir")")
            fi
        done
    fi
}

# Возвращает массив доступных версий (каталоги в packages/)
get_available_versions() {
    AVAILABLE_VERSIONS=()
    if [[ -d "$PACKAGES_DIR" ]]; then
        local dir ver crs_match
        for dir in "$PACKAGES_DIR"/*/; do
            [[ -d "$dir" ]] || continue
            ver=$(basename "$dir")
            # Проверяем что внутри есть хотя бы crs-пакет
            crs_match=$(find "$dir" -maxdepth 1 -name '1c-enterprise-*-crs_*.deb' ! -name '*-nls*' 2>/dev/null | head -1)
            [[ -n "$crs_match" ]] && AVAILABLE_VERSIONS+=("$ver")
        done
    fi
}

# Проверяет наличие 4 пакетов в каталоге версии
validate_version_packages() {
    local ver="$1"
    local dir="${PACKAGES_DIR}/${ver}"

    [[ -d "$dir" ]] || return 1

    local kind found
    for kind in common server ws crs; do
        found=$(find "$dir" -maxdepth 1 -name "1c-enterprise-*-${kind}_*.deb" ! -name '*-nls*' 2>/dev/null | head -1)
        [[ -n "$found" ]] || return 1
    done
    return 0
}

# Определяем пользователя и группу 1С
detect_1c_user() {
    SVC_USER="usr1cv8"
    SVC_GROUP=""
    if id "$SVC_USER" &>/dev/null; then
        SVC_GROUP=$(id -gn "$SVC_USER")
    fi
}

# Возвращает основной IP-адрес сервера (или "127.0.0.1" если не удалось)
get_primary_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "${ip:-127.0.0.1}"
}

# Однократная проверка целостности активной версии за сессию.
# Если в systemd-юните указана версия с удалённым бинарником — предлагает
# автоматически переключиться на установленную (если такая есть).
PHANTOM_CHECK_DONE=0
check_and_offer_phantom_fix() {
    [[ "$PHANTOM_CHECK_DONE" -eq 1 ]] && return 0
    [[ "$ACTIVE_VERSION_PHANTOM" -ne 1 ]] && { PHANTOM_CHECK_DONE=1; return 0; }

    # Нашли проблему — показываем один раз
    echo ""
    log_warn "ОБНАРУЖЕНА ПРОБЛЕМА: активная версия в systemd-юните — фантом"
    echo "    Юнит:     /etc/systemd/system/${SERVICE_NAME}.service"
    echo "    Указана:  ${ACTIVE_VERSION}"
    echo "    Бинарник: ${ACTIVE_CRSERVER_BIN} — НЕ СУЩЕСТВУЕТ"

    if [[ ${#INSTALLED_VERSIONS[@]} -eq 0 ]]; then
        log_warn "  Установленных версий нет — установите версию через меню."
        echo ""
        read -rp "  Нажмите Enter..." _
        PHANTOM_CHECK_DONE=1
        return 0
    fi

    local target="${INSTALLED_VERSIONS[0]}"
    echo "    Доступна: ${target}"
    echo ""
    read -rp "  Переключить службу на ${target} сейчас? (Y/n): " ans
    PHANTOM_CHECK_DONE=1
    if [[ "$ans" =~ ^[Nn]$ ]]; then
        log_warn "Пропущено. Переключите вручную через меню «Управление версиями»."
        sleep 1
        return 0
    fi

    switch_to_version "$target"
    # Перечитываем состояние после фикса
    detect_active_version
    get_installed_versions
    read -rp "  Нажмите Enter..." _
}

# ============================================================================
#  УПРАВЛЕНИЕ ВЕРСИЯМИ — МЕНЮ
# ============================================================================

do_version_menu() {
    while true; do
        detect_active_version
        get_installed_versions
        get_available_versions

        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Управление версиями"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""

        # Активная версия
        echo -n "  Активная версия:  "
        if [[ -n "$ACTIVE_VERSION" ]]; then
            if [[ "$ACTIVE_VERSION_PHANTOM" -eq 1 ]]; then
                echo -e "${RED}${ACTIVE_VERSION} (фантом — бинарник удалён)${NC}"
            else
                echo -e "${GREEN}${ACTIVE_VERSION}${NC}"
            fi
        else
            echo -e "${YELLOW}не установлена${NC}"
        fi

        # Установленные
        echo -n "  Установленные:    "
        if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
            local first=1
            for v in "${INSTALLED_VERSIONS[@]}"; do
                [[ $first -eq 0 ]] && echo -n ", "
                if [[ "$v" == "$ACTIVE_VERSION" && "$ACTIVE_VERSION_PHANTOM" -eq 0 ]]; then
                    echo -ne "${GREEN}${v}${NC} ◄"
                else
                    echo -n "$v"
                fi
                first=0
            done
            echo ""
        else
            echo "(нет)"
        fi

        # Доступные пакеты
        echo -n "  Пакеты (packages/): "
        if [[ ${#AVAILABLE_VERSIONS[@]} -gt 0 ]]; then
            local first=1
            for v in "${AVAILABLE_VERSIONS[@]}"; do
                [[ $first -eq 0 ]] && echo -n ", "
                # Помечаем уже установленные
                local installed=0
                for iv in "${INSTALLED_VERSIONS[@]}"; do
                    [[ "$iv" == "$v" ]] && installed=1
                done
                if [[ $installed -eq 1 ]]; then
                    echo -ne "${CYAN}${v}${NC} ✓"
                else
                    echo -n "$v"
                fi
                first=0
            done
            echo ""
        else
            echo "(пусто)"
        fi

        echo ""
        echo "  1) Установить версию"
        echo "  2) Удалить версию"
        echo "  3) Переключить активную версию"
        echo "  4) Импорт пакетов в packages/"
        echo "  5) Полная установка (первый раз)"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1) do_install_version ;;
            2) do_uninstall_version ;;
            3) do_switch_version ;;
            4) do_import_packages ;;
            5) do_full_install ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

# ============================================================================
#  УСТАНОВКА ВЕРСИИ
# ============================================================================

do_install_version() {
    get_available_versions
    get_installed_versions

    # Фильтруем: только ещё не установленные
    local to_install=()
    for v in "${AVAILABLE_VERSIONS[@]}"; do
        local already=0
        for iv in "${INSTALLED_VERSIONS[@]}"; do
            [[ "$iv" == "$v" ]] && already=1
        done
        [[ $already -eq 0 ]] && to_install+=("$v")
    done

    if [[ ${#to_install[@]} -eq 0 && ${#AVAILABLE_VERSIONS[@]} -eq 0 ]]; then
        echo ""
        log_warn "Нет доступных пакетов в ${PACKAGES_DIR}/"
        echo ""
        echo "  Создайте каталог с версией и положите туда 4 .deb пакета:"
        echo "    mkdir -p ${PACKAGES_DIR}/8.3.25.1560"
        echo "    cp 1c-enterprise-*-{common,server,ws,crs}_*.deb ${PACKAGES_DIR}/8.3.25.1560/"
        echo ""
        read -rp "  Нажмите Enter..." _
        return
    fi

    if [[ ${#to_install[@]} -eq 0 ]]; then
        log_info "Все доступные версии уже установлены"
        echo ""
        echo "  Для переустановки сначала удалите версию, затем установите заново."
        echo ""
        read -rp "  Нажмите Enter..." _
        return
    fi

    echo ""
    echo "  Доступные для установки:"
    local idx=0
    for v in "${to_install[@]}"; do
        idx=$((idx + 1))
        echo "    ${idx}) ${v}"
    done
    echo ""
    read -rp "  Номер версии (или 0 для отмены): " num

    if [[ "$num" == "0" || -z "$num" ]]; then
        return
    fi

    if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#to_install[@]} ]]; then
        local selected="${to_install[$((num - 1))]}"
        install_version "$selected"
        read -rp "  Нажмите Enter..." _
    else
        log_error "Неверный номер"
    fi
}

install_version() {
    local ver="$1"
    local pkg_dir="${PACKAGES_DIR}/${ver}"

    echo ""
    log_step "Установка версии ${ver}..."

    if ! validate_version_packages "$ver"; then
        log_error "Неполный набор пакетов в ${pkg_dir}/"
        echo "  Нужны: common, server, ws, crs"
        return 1
    fi

    local COMMON_PKG SERVER_PKG WS_PKG CRS_PKG
    COMMON_PKG=$(find "$pkg_dir" -maxdepth 1 -name "1c-enterprise-*-common_*.deb" ! -name "*-nls*" 2>/dev/null | head -1)
    SERVER_PKG=$(find "$pkg_dir" -maxdepth 1 -name "1c-enterprise-*-server_*.deb" ! -name "*-nls*" 2>/dev/null | head -1)
    WS_PKG=$(find "$pkg_dir" -maxdepth 1 -name "1c-enterprise-*-ws_*.deb"         ! -name "*-nls*" 2>/dev/null | head -1)
    CRS_PKG=$(find "$pkg_dir" -maxdepth 1 -name "1c-enterprise-*-crs_*.deb"       ! -name "*-nls*" 2>/dev/null | head -1)

    if [[ -z "$COMMON_PKG" || -z "$SERVER_PKG" || -z "$WS_PKG" || -z "$CRS_PKG" ]]; then
        log_error "Не удалось найти один из пакетов в ${pkg_dir}/"
        return 1
    fi

    echo "  Пакеты:"
    echo "    common: $(basename "$COMMON_PKG")"
    echo "    server: $(basename "$SERVER_PKG")"
    echo "    ws:     $(basename "$WS_PKG")"
    echo "    crs:    $(basename "$CRS_PKG")"
    echo ""

    local pkg dpkg_failed=0
    for pkg in "$COMMON_PKG" "$SERVER_PKG" "$WS_PKG" "$CRS_PKG"; do
        if ! dpkg -i "$pkg" >/tmp/crserver-dpkg.log 2>&1; then
            dpkg_failed=1
            log_warn "dpkg -i $(basename "$pkg") завершился с ошибкой:"
            tail -5 /tmp/crserver-dpkg.log | sed 's/^/    /'
        fi
    done
    rm -f /tmp/crserver-dpkg.log

    if ! apt-get install -f -y -qq >/dev/null 2>&1; then
        log_warn "apt-get install -f не смог автоматически починить зависимости"
        dpkg_failed=1
    fi

    if [[ $dpkg_failed -eq 1 ]]; then
        log_warn "Установка пакетов прошла с ошибками, проверьте вывод выше"
    fi

    local crserver_bin="/opt/1cv8/x86_64/${ver}/crserver"
    if [[ ! -f "$crserver_bin" ]]; then
        log_error "crserver не найден: $crserver_bin"
        return 1
    fi

    log_info "Версия ${ver} установлена"

    # Отключаем srv1cv8 если появился
    if systemctl list-unit-files 2>/dev/null | grep -q "srv1cv8"; then
        systemctl stop srv1cv8 2>/dev/null || true
        systemctl disable srv1cv8 2>/dev/null || true
    fi
}

# ============================================================================
#  УДАЛЕНИЕ ВЕРСИИ
# ============================================================================

do_uninstall_version() {
    get_installed_versions
    detect_active_version

    if [[ ${#INSTALLED_VERSIONS[@]} -eq 0 ]]; then
        log_warn "Нет установленных версий"
        read -rp "  Нажмите Enter..." _
        return
    fi

    echo ""
    echo "  Установленные версии:"
    local idx=0
    for v in "${INSTALLED_VERSIONS[@]}"; do
        idx=$((idx + 1))
        if [[ "$v" == "$ACTIVE_VERSION" ]]; then
            echo -e "    ${idx}) ${v}  ${YELLOW}← активная${NC}"
        else
            echo "    ${idx}) ${v}"
        fi
    done
    echo ""
    read -rp "  Номер версии для удаления (или 0 для отмены): " num

    if [[ "$num" == "0" || -z "$num" ]]; then
        return
    fi

    if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#INSTALLED_VERSIONS[@]} ]]; then
        local selected="${INSTALLED_VERSIONS[$((num - 1))]}"

        if [[ "$selected" == "$ACTIVE_VERSION" ]]; then
            echo ""
            log_warn "Версия ${selected} сейчас активна! Служба будет остановлена."
            read -rp "  Продолжить? (y/N): " answer
            if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                return
            fi
            systemctl stop ${SERVICE_NAME} 2>/dev/null || true
        fi

        uninstall_version "$selected"
        read -rp "  Нажмите Enter..." _
    else
        log_error "Неверный номер"
    fi
}

uninstall_version() {
    local ver="$1"
    echo ""
    log_step "Удаление версии ${ver}..."

    # Удаляем пакеты конкретной версии
    dpkg --purge "1c-enterprise-${ver}-crs"    2>/dev/null || true
    dpkg --purge "1c-enterprise-${ver}-ws"     2>/dev/null || true
    dpkg --purge "1c-enterprise-${ver}-server" 2>/dev/null || true
    dpkg --purge "1c-enterprise-${ver}-common" 2>/dev/null || true
    apt-get autoremove -y -qq > /dev/null 2>&1 || true

    # Проверяем
    if [[ -f "/opt/1cv8/x86_64/${ver}/crserver" ]]; then
        log_warn "Файлы версии ${ver} остались (возможно, заняты другими пакетами)"
    else
        log_info "Версия ${ver} удалена"
    fi

    # Если удалили активную — нужно либо переключить на другую, либо снести службу
    local was_active=0
    [[ "$ver" == "$ACTIVE_VERSION" ]] && was_active=1

    detect_active_version
    get_installed_versions

    if [[ $was_active -eq 1 ]]; then
        if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
            # Автоматически переключаемся на первую оставшуюся версию,
            # чтобы systemd-юнит не указывал на удалённый бинарник
            local fallback="${INSTALLED_VERSIONS[0]}"
            log_warn "Активная версия удалена — переключаюсь на ${fallback}"
            ACTIVE_VERSION="$fallback"
            ACTIVE_CRSERVER_BIN="/opt/1cv8/x86_64/${fallback}/crserver"
            regenerate_service
            systemctl restart ${SERVICE_NAME} 2>/dev/null || \
                log_warn "Служба не запустилась автоматически — проверьте journalctl -u ${SERVICE_NAME}"
        else
            # Удаляем службу — версий не осталось
            if [[ -f /etc/systemd/system/${SERVICE_NAME}.service ]]; then
                systemctl disable ${SERVICE_NAME} 2>/dev/null || true
                rm -f /etc/systemd/system/${SERVICE_NAME}.service
                systemctl daemon-reload
                log_info "Служба удалена (нет установленных версий)"
            fi
        fi
    fi
}

# ============================================================================
#  ПЕРЕКЛЮЧЕНИЕ ВЕРСИИ
# ============================================================================

do_switch_version() {
    get_installed_versions
    detect_active_version

    if [[ ${#INSTALLED_VERSIONS[@]} -eq 0 ]]; then
        log_warn "Нет установленных версий"
        read -rp "  Нажмите Enter..." _
        return
    fi

    # Спецслучай: ровно одна установленная версия.
    # Если активная — фантом (юнит ссылается на удалённый бинарник),
    # переключаемся на единственную реальную автоматически.
    if [[ ${#INSTALLED_VERSIONS[@]} -eq 1 ]]; then
        local only="${INSTALLED_VERSIONS[0]}"
        if [[ "$ACTIVE_VERSION_PHANTOM" -eq 1 ]]; then
            log_warn "Активная версия (${ACTIVE_VERSION}) указана в systemd-юните,"
            log_warn "но её бинарник отсутствует. Доступна только: ${only}"
            echo ""
            read -rp "  Переключить службу на ${only}? (Y/n): " ans
            if [[ "$ans" =~ ^[Nn]$ ]]; then
                return
            fi
            switch_to_version "$only"
            read -rp "  Нажмите Enter..." _
            return
        fi
        if [[ "$only" == "$ACTIVE_VERSION" ]]; then
            log_info "Установлена только одна версия (${only}), она уже активна"
        else
            log_warn "Установлена только одна версия (${only}), но активная другая (${ACTIVE_VERSION})"
            echo ""
            read -rp "  Переключить службу на ${only}? (Y/n): " ans
            if [[ "$ans" =~ ^[Nn]$ ]]; then
                return
            fi
            switch_to_version "$only"
        fi
        read -rp "  Нажмите Enter..." _
        return
    fi

    echo ""
    if [[ "$ACTIVE_VERSION_PHANTOM" -eq 1 ]]; then
        log_warn "Внимание: активная версия в юните (${ACTIVE_VERSION}) — фантом (бинарник удалён)"
        echo ""
    fi

    echo "  Установленные версии:"
    local idx=0
    local v
    for v in "${INSTALLED_VERSIONS[@]}"; do
        idx=$((idx + 1))
        if [[ "$v" == "$ACTIVE_VERSION" && "$ACTIVE_VERSION_PHANTOM" -eq 0 ]]; then
            echo -e "    ${idx}) ${v}  ${GREEN}← активная${NC}"
        else
            echo "    ${idx}) ${v}"
        fi
    done
    echo ""
    read -rp "  Переключить на версию (номер, или 0 для отмены): " num

    if [[ "$num" == "0" || -z "$num" ]]; then
        return
    fi

    if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#INSTALLED_VERSIONS[@]} ]]; then
        local selected="${INSTALLED_VERSIONS[$((num - 1))]}"

        # Если активная — фантом, любое переключение оправдано (даже если совпадает имя)
        if [[ "$selected" == "$ACTIVE_VERSION" && "$ACTIVE_VERSION_PHANTOM" -eq 0 ]]; then
            log_info "Версия ${selected} уже активна"
            read -rp "  Нажмите Enter..." _
            return
        fi

        switch_to_version "$selected"
        read -rp "  Нажмите Enter..." _
    else
        log_error "Неверный номер"
    fi
}

switch_to_version() {
    local ver="$1"
    local new_bin="/opt/1cv8/x86_64/${ver}/crserver"

    if [[ ! -f "$new_bin" ]]; then
        log_error "crserver не найден: $new_bin"
        return 1
    fi
    if [[ ! -x "$new_bin" ]]; then
        log_warn "Файл $new_bin не исполняемый, ставлю +x"
        chmod +x "$new_bin" 2>/dev/null || true
    fi

    log_step "Переключение на версию ${ver}..."

    # 1) Останавливаем текущую службу с явным ожиданием полного завершения
    if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
        log_step "Остановка текущей службы..."
        if ! systemctl stop ${SERVICE_NAME}; then
            log_warn "systemctl stop вернул ошибку, продолжаю"
        fi
        # Ждём, пока порт освободится (до 15 секунд)
        local i
        for i in {1..15}; do
            if ! ss -tln 2>/dev/null | grep -q ":${REPO_PORT}\b"; then
                break
            fi
            sleep 1
        done
        if ss -tln 2>/dev/null | grep -q ":${REPO_PORT}\b"; then
            log_warn "Порт ${REPO_PORT} всё ещё занят — попытка форсированного завершения"
            pkill -TERM -f "crserver.*-port[ =]*${REPO_PORT}" 2>/dev/null || true
            sleep 2
            pkill -KILL -f "crserver.*-port[ =]*${REPO_PORT}" 2>/dev/null || true
            sleep 1
        fi
    fi

    # 2) Пересоздаём systemd-юнит с новой версией
    ACTIVE_VERSION="$ver"
    ACTIVE_CRSERVER_BIN="$new_bin"
    if ! regenerate_service; then
        log_error "Не удалось пересоздать systemd-службу"
        return 1
    fi

    # 3) Запускаем (без падения скрипта при ошибке)
    log_step "Запуск службы..."
    local start_rc=0
    systemctl start ${SERVICE_NAME} || start_rc=$?

    # Дать systemd шанс stабилизироваться
    sleep 2

    if systemctl is-active --quiet ${SERVICE_NAME}; then
        log_info "Переключено на версию ${ver} — служба запущена"
        if ss -tln 2>/dev/null | grep -q ":${REPO_PORT}\b"; then
            log_info "Порт ${REPO_PORT} слушается"
        else
            log_warn "Служба активна, но порт ${REPO_PORT} ещё не слушается (подождите несколько секунд)"
        fi
        return 0
    else
        log_error "Служба не запустилась (systemctl start exit=${start_rc})"
        echo "  Последние строки журнала:"
        journalctl -u ${SERVICE_NAME} -n 20 --no-pager 2>/dev/null | sed 's/^/    /' || true
        echo ""
        echo "  Полный лог: journalctl -u ${SERVICE_NAME} -n 100"
        return 1
    fi
}

# ============================================================================
#  ИМПОРТ ПАКЕТОВ
# ============================================================================

do_import_packages() {
    echo ""
    echo -e "${BOLD}  Импорт пакетов в ${PACKAGES_DIR}/${NC}"
    echo ""
    echo "  Варианты:"
    echo "  1) Из текущего каталога (${SCRIPT_DIR})"
    echo "  2) Из указанного пути"
    echo ""
    echo "  0) ← Назад"
    echo ""
    read -rp "  Выберите: " choice

    local source_dir=""
    case $choice in
        1) source_dir="$SCRIPT_DIR" ;;
        2)
            read -rp "  Путь к каталогу с .deb файлами: " source_dir
            if [[ ! -d "$source_dir" ]]; then
                log_error "Каталог не найден: $source_dir"
                return
            fi
            ;;
        0) return ;;
        *) log_warn "Неверный выбор"; return ;;
    esac

    # Ищем .deb пакеты crs в источнике
    local found_versions=()
    local crs_file ver fv dup
    while IFS= read -r crs_file; do
        ver=$(basename "$crs_file" | grep -oP '8\.3\.\d+\.\d+' || true)
        if [[ -n "$ver" ]]; then
            # Проверяем что нет дубликатов
            dup=0
            for fv in "${found_versions[@]+"${found_versions[@]}"}"; do
                [[ "$fv" == "$ver" ]] && dup=1
            done
            [[ $dup -eq 0 ]] && found_versions+=("$ver")
        fi
    done < <(find "$source_dir" -maxdepth 1 -name "1c-enterprise-*-crs_*.deb" ! -name "*-nls*" 2>/dev/null)

    if [[ ${#found_versions[@]} -eq 0 ]]; then
        log_warn "Не найдены .deb пакеты 1С в ${source_dir}/"
        read -rp "  Нажмите Enter..." _
        return
    fi

    local dest deb count failed
    for ver in "${found_versions[@]}"; do
        dest="${PACKAGES_DIR}/${ver}"
        mkdir -p "$dest"

        count=0
        failed=0
        for deb in "$source_dir"/1c-enterprise-${ver}-*.deb; do
            [[ -f "$deb" ]] || continue
            # Пропускаем NLS-пакеты (валидатор их игнорирует)
            [[ "$(basename "$deb")" == *-nls* ]] && continue
            if cp "$deb" "$dest/"; then
                count=$((count + 1))
            else
                failed=$((failed + 1))
                log_warn "  не удалось скопировать: $(basename "$deb")"
            fi
        done

        if [[ $failed -eq 0 ]]; then
            log_info "Версия ${ver}: скопировано ${count} пакетов → ${dest}/"
        else
            log_warn "Версия ${ver}: скопировано ${count}, ошибок ${failed} → ${dest}/"
        fi
    done

    echo ""
    read -rp "  Нажмите Enter..." _
}

# ============================================================================
#  ПОЛНАЯ УСТАНОВКА (ПЕРВЫЙ РАЗ)
# ============================================================================

do_full_install() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Полная установка сервера хранилища 1С${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""

    # --- Выбор версии ---
    get_available_versions

    if [[ ${#AVAILABLE_VERSIONS[@]} -eq 0 ]]; then
        log_warn "Нет доступных пакетов в ${PACKAGES_DIR}/"
        echo ""
        echo "  Шаг 1: Создайте каталог версии:"
        echo "    mkdir -p ${PACKAGES_DIR}/8.3.25.1560"
        echo ""
        echo "  Шаг 2: Скопируйте 4 .deb пакета:"
        echo "    cp 1c-enterprise-*-{common,server,ws,crs}_*.deb ${PACKAGES_DIR}/8.3.25.1560/"
        echo ""
        echo "  Или используйте пункт '4) Импорт пакетов' для автоматического импорта."
        echo ""
        read -rp "  Нажмите Enter..." _
        return
    fi

    local target_ver=""
    if [[ ${#AVAILABLE_VERSIONS[@]} -eq 1 ]]; then
        target_ver="${AVAILABLE_VERSIONS[0]}"
        echo "  Доступна версия: ${target_ver}"
    else
        echo "  Доступные версии:"
        local idx=0
        for v in "${AVAILABLE_VERSIONS[@]}"; do
            idx=$((idx + 1))
            echo "    ${idx}) ${v}"
        done
        echo ""
        read -rp "  Выберите версию для установки: " num
        if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#AVAILABLE_VERSIONS[@]} ]]; then
            target_ver="${AVAILABLE_VERSIONS[$((num - 1))]}"
        else
            log_error "Неверный номер"
            return
        fi
    fi

    if ! validate_version_packages "$target_ver"; then
        log_error "Неполный набор пакетов для версии ${target_ver}"
        echo "  Нужны: common, server, ws, crs"
        read -rp "  Нажмите Enter..." _
        return
    fi

    echo ""
    read -rp "  Начать полную установку версии ${target_ver}? (Y/n): " answer
    if [[ "$answer" =~ ^[Nn]$ ]]; then
        return
    fi

    # --- 1. Системные зависимости ---
    log_step "Установка системных зависимостей..."
    apt-get update -qq
    apt-get install -y -qq \
        wget tar fontconfig libfreetype6 libgsf-1-114 \
        libglib2.0-0 libodbc2 imagemagick locales curl \
        iptables-persistent \
        > /dev/null 2>&1 || true
    log_info "Зависимости установлены"

    # --- 2. Локаль ---
    log_step "Настройка локали ru_RU.UTF-8..."
    sed -i 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    locale-gen > /dev/null 2>&1 || true
    log_info "Локаль настроена"

    # --- 3. Установка пакетов ---
    install_version "$target_ver"

    # --- 4. Пользователь и каталоги ---
    log_step "Настройка пользователя и каталогов..."
    detect_1c_user

    if [[ -z "$SVC_GROUP" ]]; then
        groupadd -r grp1cv8 2>/dev/null || true
        useradd -r -s /bin/bash -m -d /home/usr1cv8 -g grp1cv8 usr1cv8 2>/dev/null || true
        SVC_GROUP="grp1cv8"
        log_info "Создан пользователь usr1cv8:grp1cv8"
    else
        log_info "Пользователь: ${SVC_USER}:${SVC_GROUP}"
    fi

    mkdir -p "$REPO_DIR" "$LOG_DIR" "$BACKUP_DIR"
    chown -R "${SVC_USER}:${SVC_GROUP}" "$REPO_DIR"
    chown -R "${SVC_USER}:${SVC_GROUP}" "$LOG_DIR"
    log_info "Каталоги созданы"

    # --- 5. Systemd-служба ---
    ACTIVE_VERSION="$target_ver"
    ACTIVE_CRSERVER_BIN="/opt/1cv8/x86_64/${target_ver}/crserver"
    log_step "Создание systemd-службы..."
    if ! regenerate_service; then
        log_error "Не удалось создать systemd-службу"
        return 1
    fi
    log_info "Служба создана"

    # --- 6. Файрвол ---
    log_step "Настройка файрвола..."
    setup_firewall_chain
    log_info "Файрвол настроен"

    # --- 7. Запуск ---
    log_step "Запуск сервера хранилища..."
    local start_rc=0
    systemctl start ${SERVICE_NAME} || start_rc=$?
    sleep 2

    if systemctl is-active --quiet ${SERVICE_NAME}; then
        log_info "Сервер хранилища ЗАПУЩЕН"
    else
        log_error "Не удалось запустить (systemctl start exit=${start_rc})"
        echo "  Последние строки журнала:"
        journalctl -u ${SERVICE_NAME} -n 20 --no-pager 2>/dev/null | sed 's/^/    /' || true
        return 1
    fi

    if ss -tlnp | grep -q ":${REPO_PORT}"; then
        log_info "Порт ${REPO_PORT} слушается"
    fi

    save_config

    # --- Итог ---
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  УСТАНОВКА ЗАВЕРШЕНА${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    IP_ADDR=$(get_primary_ip)
    echo ""
    echo "  Версия:   ${target_ver}"
    echo "  Адрес:    tcp://${IP_ADDR}:${REPO_PORT}/<имя_хранилища>"
    echo "  Пример:   tcp://${IP_ADDR}:${REPO_PORT}/trade_dev"
    echo ""
    read -rp "  Нажмите Enter..." _
}

# ============================================================================
#  ПОЛНОЕ УДАЛЕНИЕ
# ============================================================================

do_full_uninstall() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${RED}  Полное удаление сервера хранилища 1С${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""

    get_installed_versions

    echo "  Что будет удалено:"
    echo "    • Служба ${SERVICE_NAME}"
    for v in "${INSTALLED_VERSIONS[@]}"; do
        echo "    • Пакеты версии ${v}"
    done
    echo "    • Правила файрвола"
    echo ""
    echo -e "  ${YELLOW}Каталог хранилищ ${REPO_DIR} НЕ удаляется${NC}"
    echo -e "  ${YELLOW}Каталог пакетов ${PACKAGES_DIR} НЕ удаляется${NC}"
    echo ""
    read -rp "  Введите 'DELETE' для подтверждения: " answer
    if [[ "$answer" != "DELETE" ]]; then
        log_warn "Отменено"
        return
    fi

    # Остановка и удаление службы
    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    if [[ -f /etc/systemd/system/${SERVICE_NAME}.service ]]; then
        systemctl disable ${SERVICE_NAME} 2>/dev/null || true
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        systemctl daemon-reload
        log_info "Служба удалена"
    fi

    # Удаление всех версий
    for v in "${INSTALLED_VERSIONS[@]}"; do
        log_step "Удаление версии ${v}..."
        dpkg --purge "1c-enterprise-${v}-crs"    2>/dev/null || true
        dpkg --purge "1c-enterprise-${v}-ws"     2>/dev/null || true
        dpkg --purge "1c-enterprise-${v}-server" 2>/dev/null || true
        dpkg --purge "1c-enterprise-${v}-common" 2>/dev/null || true
    done
    apt-get autoremove -y -qq > /dev/null 2>&1 || true
    log_info "Пакеты удалены"

    # Файрвол
    cleanup_firewall
    log_info "Правила файрвола очищены"

    # Конфигурация
    rm -f "$CONFIG_FILE"
    rmdir "$(dirname "$CONFIG_FILE")" 2>/dev/null || true

    echo ""
    log_info "Удаление завершено"
    echo -e "  ${YELLOW}Каталог ${REPO_DIR} сохранён. Удалите вручную если не нужен.${NC}"
    echo ""
}

# ============================================================================
#  УПРАВЛЕНИЕ СЛУЖБОЙ
# ============================================================================

do_service_menu() {
    while true; do
        detect_active_version

        local status_text status_color
        if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
            status_text="РАБОТАЕТ"
            status_color="${GREEN}"
        else
            status_text="ОСТАНОВЛЕН"
            status_color="${RED}"
        fi

        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Управление службой   Статус: ${status_color}${status_text}${NC}"
        if [[ -n "$ACTIVE_VERSION" ]]; then
            echo -e "  Версия: ${ACTIVE_VERSION}"
        fi
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""
        echo "  1) Запустить"
        echo "  2) Остановить"
        echo "  3) Перезапустить"
        echo "  4) Подробный статус"
        echo "  5) Просмотр логов (последние 50 строк)"
        echo "  6) Логи в реальном времени (Ctrl+C для выхода)"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1)
                if systemctl start ${SERVICE_NAME}; then
                    log_info "Запущен"
                else
                    log_error "Ошибка запуска (journalctl -u ${SERVICE_NAME} -n 20)"
                fi
                sleep 1
                ;;
            2)
                if systemctl stop ${SERVICE_NAME}; then
                    log_info "Остановлен"
                else
                    log_error "Ошибка остановки"
                fi
                ;;
            3)
                if systemctl restart ${SERVICE_NAME}; then
                    log_info "Перезапущен"
                else
                    log_error "Ошибка перезапуска (journalctl -u ${SERVICE_NAME} -n 20)"
                fi
                sleep 1
                ;;
            4)
                echo ""
                systemctl status ${SERVICE_NAME} --no-pager 2>/dev/null || log_warn "Служба не найдена"
                echo ""
                if ss -tlnp | grep -q ":${REPO_PORT}"; then
                    log_info "Порт ${REPO_PORT} слушается"
                else
                    log_warn "Порт ${REPO_PORT} не слушается"
                fi
                echo ""
                read -rp "  Нажмите Enter..." _
                ;;
            5)
                echo ""
                journalctl -u ${SERVICE_NAME} -n 50 --no-pager 2>/dev/null || log_warn "Нет логов"
                echo ""
                read -rp "  Нажмите Enter..." _
                ;;
            6)
                echo ""
                echo "  (Ctrl+C для выхода)"
                journalctl -u ${SERVICE_NAME} -f 2>/dev/null || true
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

# ============================================================================
#  НАСТРОЙКА СЕРВЕРА
# ============================================================================

do_settings_menu() {
    while true; do
        load_config
        detect_active_version

        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Настройки сервера"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""
        echo "  Текущие параметры:"
        echo "    Активная версия:   ${ACTIVE_VERSION:-не установлена}"
        echo "    Порт:              ${REPO_PORT}"
        echo "    Каталог хранилищ:  ${REPO_DIR}"
        echo "    Каталог логов:     ${LOG_DIR}"
        echo "    Каталог бэкапов:   ${BACKUP_DIR}"
        echo "    Каталог пакетов:   ${PACKAGES_DIR}"
        echo ""
        echo "  1) Изменить порт"
        echo "  2) Изменить каталог хранилищ"
        echo "  3) Изменить каталог бэкапов"
        echo "  4) Пересоздать systemd-службу"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1)
                read -rp "  Новый порт [${REPO_PORT}]: " new_port
                if [[ -n "$new_port" && "$new_port" =~ ^[0-9]+$ ]]; then
                    REPO_PORT="$new_port"
                    save_config
                    regenerate_service
                    log_info "Порт изменён на ${REPO_PORT}. Перезапустите службу."
                fi
                ;;
            2)
                read -rp "  Новый каталог [${REPO_DIR}]: " new_dir
                if [[ -n "$new_dir" ]]; then
                    REPO_DIR="$new_dir"
                    detect_1c_user
                    mkdir -p "$REPO_DIR"
                    chown -R "${SVC_USER}:${SVC_GROUP}" "$REPO_DIR"
                    save_config
                    regenerate_service
                    log_info "Каталог изменён. Перезапустите службу."
                fi
                ;;
            3)
                read -rp "  Новый каталог бэкапов [${BACKUP_DIR}]: " new_dir
                if [[ -n "$new_dir" ]]; then
                    BACKUP_DIR="$new_dir"
                    mkdir -p "$BACKUP_DIR"
                    save_config
                    log_info "Каталог бэкапов: ${BACKUP_DIR}"
                fi
                ;;
            4)
                regenerate_service
                log_info "Служба пересоздана. Перезапустите через меню управления."
                read -rp "  Нажмите Enter..." _
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

regenerate_service() {
    # detect_active_version вызывается только если ACTIVE_VERSION/_BIN ещё не заданы,
    # иначе мы потеряем ручное переключение, выполненное вызывающим кодом.
    if [[ -z "${ACTIVE_VERSION:-}" || -z "${ACTIVE_CRSERVER_BIN:-}" ]]; then
        detect_active_version
    fi
    detect_1c_user

    local bin="${ACTIVE_CRSERVER_BIN:-}"
    local ver="${ACTIVE_VERSION:-}"

    if [[ -z "$bin" || ! -f "$bin" ]]; then
        log_error "crserver не найден. Сначала установите версию."
        return 1
    fi

    if [[ -z "$SVC_USER" || -z "$SVC_GROUP" ]]; then
        log_error "Не определён системный пользователь 1С (usr1cv8)"
        return 1
    fi

    # Валидация путей: должны быть абсолютными, без переносов строк
    local p
    for p in "$REPO_DIR" "$LOG_DIR"; do
        if [[ -z "$p" || "$p" != /* || "$p" == *$'\n'* ]]; then
            log_error "Некорректный путь в конфигурации: '${p}' (ожидается абсолютный путь)"
            return 1
        fi
    done

    if ! [[ "$REPO_PORT" =~ ^[0-9]+$ ]] || (( REPO_PORT < 1 || REPO_PORT > 65535 )); then
        log_error "Некорректный порт: '${REPO_PORT}'"
        return 1
    fi

    # Гарантируем существование каталогов, на которые ссылается ReadWritePaths,
    # иначе systemd откажется стартовать юнит ("Failed to set up mount namespacing")
    mkdir -p "$REPO_DIR" "$LOG_DIR" 2>/dev/null || true

    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=1C:Enterprise Configuration Repository Server ${ver}
Documentation=https://its.1c.ru
After=network.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_GROUP}

ExecStart=${bin} -d ${REPO_DIR} -port ${REPO_PORT}

Restart=on-failure
RestartSec=10
TimeoutStopSec=30

StandardOutput=journal
StandardError=journal
SyslogIdentifier=crserver

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${REPO_DIR} ${LOG_DIR}
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    if ! systemctl daemon-reload; then
        log_error "systemctl daemon-reload завершился с ошибкой"
        return 1
    fi
    systemctl enable ${SERVICE_NAME} > /dev/null 2>&1 || \
        log_warn "systemctl enable вернул ошибку (продолжаю)"
    return 0
}

# ============================================================================
#  УПРАВЛЕНИЕ ХРАНИЛИЩАМИ
# ============================================================================
#
# Хранилище 1С на сервере — это подкаталог в REPO_DIR/<имя>/. Внутри
# присутствуют файлы вроде 1cv8ddb.lst, cache/, data/. Их структуру создаёт
# и поддерживает конфигуратор 1С при первом подключении / работе.
#
# Скрипт умеет только файловые операции: создать пустой каталог-заготовку,
# удалить, переименовать, бэкапить/восстанавливать конкретное хранилище,
# показывать инфо. Создание структуры (инициализация хранилища) и работа
# с историей версий — задача конфигуратора 1С.

# Имя хранилища: только латиница/цифры/_/- , 1..64 символа
validate_repo_name() {
    local name="$1"
    [[ -z "$name" ]] && return 1
    [[ ${#name} -gt 64 ]] && return 1
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    return 0
}

# Возвращает массив существующих хранилищ через имя массива
# Использование: get_repo_list arr_name
get_repo_list() {
    local _out_var="$1"
    local _result=()
    if [[ -d "$REPO_DIR" ]]; then
        local _dir
        for _dir in "$REPO_DIR"/*/; do
            [[ -d "$_dir" ]] || continue
            _result+=("$(basename "$_dir")")
        done
    fi
    # Передаём массив через namedref
    local -n _ref="$_out_var"
    _ref=("${_result[@]+"${_result[@]}"}")
}

# Признаки «непустого» хранилища 1С — наличие хотя бы одного из файлов
repo_looks_initialized() {
    local dir="$1"
    [[ -f "$dir/1cv8ddb.lst" ]] && return 0
    [[ -d "$dir/cache" ]]      && return 0
    [[ -d "$dir/data" ]]       && return 0
    [[ -f "$dir/v8inforeg.lst" ]] && return 0
    return 1
}

do_repo_menu() {
    while true; do
        local repos=()
        get_repo_list repos
        local ip_addr
        ip_addr=$(get_primary_ip)

        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Хранилища конфигураций"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo "  Каталог: ${REPO_DIR}"
        echo ""

        if [[ ${#repos[@]} -eq 0 ]]; then
            echo "  (хранилищ нет)"
        else
            echo "  Существующие:"
            echo "  ─────────────────────────────────────────────"
            local idx=0 r size status
            for r in "${repos[@]}"; do
                idx=$((idx + 1))
                size=$(du -sh "${REPO_DIR}/${r}" 2>/dev/null | awk '{print $1}')
                if repo_looks_initialized "${REPO_DIR}/${r}"; then
                    status="${GREEN}init${NC}"
                else
                    status="${YELLOW}пусто${NC}"
                fi
                echo -e "    ${idx}) ${r}  [${size:-?}]  (${status})"
                echo "       → tcp://${ip_addr}:${REPO_PORT}/${r}"
            done
        fi

        echo ""
        echo "  1) Подробный список (с числом файлов и датой)"
        echo "  2) Подготовить новое хранилище (пустой каталог)"
        echo "  3) Информация о хранилище"
        echo "  4) Переименовать хранилище"
        echo "  5) Удалить хранилище"
        echo "  6) Бэкап хранилища (одного)"
        echo "  7) Восстановить хранилище из бэкапа"
        echo "  8) Проверить целостность"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1) do_repo_list_detailed; read -rp "  Нажмите Enter..." _ ;;
            2) do_repo_create;        read -rp "  Нажмите Enter..." _ ;;
            3) do_repo_info;          read -rp "  Нажмите Enter..." _ ;;
            4) do_repo_rename;        read -rp "  Нажмите Enter..." _ ;;
            5) do_repo_delete;        read -rp "  Нажмите Enter..." _ ;;
            6) do_repo_backup;        read -rp "  Нажмите Enter..." _ ;;
            7) do_repo_restore;       read -rp "  Нажмите Enter..." _ ;;
            8) do_repo_check;         read -rp "  Нажмите Enter..." _ ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

do_repo_list_detailed() {
    local repos=()
    get_repo_list repos
    if [[ ${#repos[@]} -eq 0 ]]; then
        echo ""
        echo "  (хранилищ нет)"
        return
    fi

    local ip_addr
    ip_addr=$(get_primary_ip)
    echo ""
    printf "  %-24s %8s %8s %12s  %s\n" "Имя" "Размер" "Файлов" "Изменено" "Статус"
    echo "  ─────────────────────────────────────────────────────────────────────"
    local r dir size files mtime status
    for r in "${repos[@]}"; do
        dir="${REPO_DIR}/${r}"
        size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        files=$(find "$dir" -type f 2>/dev/null | wc -l)
        mtime=$(stat -c '%y' "$dir" 2>/dev/null | cut -d. -f1 | cut -d' ' -f1)
        if repo_looks_initialized "$dir"; then
            status="init"
        else
            status="пусто"
        fi
        printf "  %-24s %8s %8s %12s  %s\n" "$r" "${size:-?}" "${files:-0}" "${mtime:-?}" "$status"
    done
    echo ""
    echo "  Подключение из конфигуратора:"
    echo "    tcp://${ip_addr}:${REPO_PORT}/<имя>"
}

do_repo_create() {
    echo ""
    read -rp "  Имя нового хранилища (латиница/цифры/_-, до 64 символов): " name
    if ! validate_repo_name "$name"; then
        log_error "Недопустимое имя"
        return 1
    fi
    local dir="${REPO_DIR}/${name}"
    if [[ -e "$dir" ]]; then
        log_error "Хранилище с таким именем уже существует: ${dir}"
        return 1
    fi

    detect_1c_user
    if [[ -z "$SVC_USER" || -z "$SVC_GROUP" ]]; then
        log_error "Не определён пользователь usr1cv8 — выполните установку"
        return 1
    fi

    mkdir -p "$dir"
    chown "${SVC_USER}:${SVC_GROUP}" "$dir"
    chmod 750 "$dir"

    log_info "Каталог создан: ${dir}"
    echo ""
    echo "  Это пустая ЗАГОТОВКА. Структура хранилища создаётся конфигуратором"
    echo "  при первом подключении:"
    echo ""
    echo "    Конфигурация → Хранилище конфигурации → Создать хранилище"
    local ip_addr
    ip_addr=$(get_primary_ip)
    echo "    Адрес: tcp://${ip_addr}:${REPO_PORT}/${name}"
}

# Возвращает имя хранилища через переменную repo_chosen, либо ""
_select_repo_interactive() {
    repo_chosen=""
    local repos=()
    get_repo_list repos
    if [[ ${#repos[@]} -eq 0 ]]; then
        log_warn "Хранилищ нет"
        return 1
    fi
    echo ""
    echo "  Выберите хранилище:"
    local idx=0 r
    for r in "${repos[@]}"; do
        idx=$((idx + 1))
        echo "    ${idx}) ${r}"
    done
    echo ""
    read -rp "  Номер (или 0 для отмены): " num
    if [[ "$num" == "0" || -z "$num" ]]; then
        return 1
    fi
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#repos[@]} )); then
        repo_chosen="${repos[$((num - 1))]}"
        return 0
    fi
    log_error "Неверный номер"
    return 1
}

do_repo_info() {
    local repo_chosen=""
    _select_repo_interactive || return
    local dir="${REPO_DIR}/${repo_chosen}"
    local ip_addr
    ip_addr=$(get_primary_ip)

    echo ""
    echo "  Информация о хранилище '${repo_chosen}'"
    echo "  ─────────────────────────────────────────────"
    echo "    Путь:       ${dir}"
    echo "    Адрес:      tcp://${ip_addr}:${REPO_PORT}/${repo_chosen}"
    echo "    Размер:     $(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    echo "    Файлов:     $(find "$dir" -type f 2>/dev/null | wc -l)"
    echo "    Каталогов:  $(find "$dir" -type d 2>/dev/null | wc -l)"
    echo "    Изменён:    $(stat -c '%y' "$dir" 2>/dev/null | cut -d. -f1)"
    echo "    Владелец:   $(stat -c '%U:%G' "$dir" 2>/dev/null)"
    echo "    Права:      $(stat -c '%a' "$dir" 2>/dev/null)"
    if repo_looks_initialized "$dir"; then
        echo "    Статус:     инициализировано"
    else
        echo "    Статус:     пустая заготовка"
    fi

    # Активные подключения к порту (грубо — все, не различим конкретное хранилище)
    if command -v ss >/dev/null 2>&1; then
        local conns
        conns=$(ss -tn 2>/dev/null | awk -v p=":${REPO_PORT}" '$0 ~ p && $1=="ESTAB" {print}' | wc -l)
        echo "    Активных подключений к порту ${REPO_PORT}: ${conns}"
    fi
}

do_repo_rename() {
    local repo_chosen=""
    _select_repo_interactive || return
    local old_name="$repo_chosen"
    local old_dir="${REPO_DIR}/${old_name}"

    echo ""
    log_warn "Переименование разорвёт URL подключения у клиентов!"
    echo "    Было:   tcp://...:${REPO_PORT}/${old_name}"
    read -rp "  Новое имя: " new_name
    if ! validate_repo_name "$new_name"; then
        log_error "Недопустимое имя"
        return 1
    fi
    if [[ "$new_name" == "$old_name" ]]; then
        log_warn "Имя не изменилось"
        return
    fi
    local new_dir="${REPO_DIR}/${new_name}"
    if [[ -e "$new_dir" ]]; then
        log_error "Хранилище с таким именем уже существует"
        return 1
    fi

    # Останавливаем службу — переименование на горячую может повредить открытые сессии
    local was_active=0
    if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
        was_active=1
        log_step "Остановка службы..."
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
        sleep 1
    fi

    if ! mv "$old_dir" "$new_dir"; then
        log_error "mv не удался"
        if [[ $was_active -eq 1 ]]; then
            systemctl start ${SERVICE_NAME} 2>/dev/null || true
        fi
        return 1
    fi

    if [[ $was_active -eq 1 ]]; then
        systemctl start ${SERVICE_NAME} 2>/dev/null || \
            log_warn "Служба не стартовала — проверьте journalctl"
    fi

    local ip_addr
    ip_addr=$(get_primary_ip)
    log_info "Переименовано: ${old_name} → ${new_name}"
    echo "    Стало: tcp://${ip_addr}:${REPO_PORT}/${new_name}"
}

do_repo_delete() {
    local repo_chosen=""
    _select_repo_interactive || return
    local name="$repo_chosen"
    local dir="${REPO_DIR}/${name}"

    echo ""
    echo "  Будет УДАЛЁН каталог:"
    echo "    ${dir}"
    echo "  Размер: $(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    echo ""
    log_warn "Это необратимо. Рекомендуется сначала сделать бэкап (пункт 6)."
    echo ""
    read -rp "  Введите имя хранилища '${name}' для подтверждения: " confirm
    if [[ "$confirm" != "$name" ]]; then
        log_warn "Отменено (имя не совпало)"
        return
    fi

    # Останавливаем службу
    local was_active=0
    if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
        was_active=1
        log_step "Остановка службы..."
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
        sleep 1
    fi

    if ! rm -rf "$dir"; then
        log_error "rm -rf завершился с ошибкой"
        if [[ $was_active -eq 1 ]]; then
            systemctl start ${SERVICE_NAME} 2>/dev/null || true
        fi
        return 1
    fi
    log_info "Удалено: ${name}"

    if [[ $was_active -eq 1 ]]; then
        systemctl start ${SERVICE_NAME} 2>/dev/null || \
            log_warn "Служба не стартовала — проверьте journalctl"
    fi
}

do_repo_backup() {
    local repo_chosen=""
    _select_repo_interactive || return
    local name="$repo_chosen"
    local src="${REPO_DIR}/${name}"

    mkdir -p "$BACKUP_DIR"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local archive="${BACKUP_DIR}/repo_${name}_${timestamp}.tar.gz"

    # Опционально приостановить службу для консистентного снимка
    local stop_service=0
    echo ""
    read -rp "  Остановить службу на время бэкапа (рекомендуется)? (Y/n): " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
        stop_service=1
    fi

    local was_active=0
    if [[ $stop_service -eq 1 ]] && systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
        was_active=1
        log_step "Остановка службы..."
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
        sleep 1
    fi

    log_step "Создание архива ${archive}..."
    if ! tar -czf "$archive" -C "$REPO_DIR" "$name" 2>/tmp/crserver-tar.log; then
        log_error "tar завершился с ошибкой:"
        tail -5 /tmp/crserver-tar.log | sed 's/^/    /'
        rm -f /tmp/crserver-tar.log "$archive"
        if [[ $was_active -eq 1 ]]; then
            systemctl start ${SERVICE_NAME} 2>/dev/null || true
        fi
        return 1
    fi
    rm -f /tmp/crserver-tar.log

    local size
    size=$(du -sh "$archive" 2>/dev/null | awk '{print $1}')
    log_info "Бэкап создан: ${archive} [${size:-?}]"

    if [[ $was_active -eq 1 ]]; then
        systemctl start ${SERVICE_NAME} 2>/dev/null || \
            log_warn "Служба не стартовала — проверьте journalctl"
    fi
}

do_repo_restore() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warn "Каталог бэкапов не существует: ${BACKUP_DIR}"
        return
    fi

    # Только архивы вида repo_<имя>_<timestamp>.tar.gz
    local backups=()
    local f
    for f in "$BACKUP_DIR"/repo_*.tar.gz; do
        [[ -f "$f" ]] && backups+=("$f")
    done
    if [[ ${#backups[@]} -eq 0 ]]; then
        log_warn "Нет бэкапов отдельных хранилищ (repo_*.tar.gz) в ${BACKUP_DIR}"
        echo "  Создайте сначала через пункт 6."
        return
    fi

    echo ""
    echo "  Доступные бэкапы:"
    local idx=0 size
    for f in "${backups[@]}"; do
        idx=$((idx + 1))
        size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        echo "    ${idx}) $(basename "$f")  [${size:-?}]"
    done
    echo ""
    read -rp "  Номер бэкапа (или 0): " num
    if [[ "$num" == "0" || -z "$num" ]]; then
        return
    fi
    if ! [[ "$num" =~ ^[0-9]+$ ]] || (( num < 1 || num > ${#backups[@]} )); then
        log_error "Неверный номер"
        return 1
    fi

    local archive="${backups[$((num - 1))]}"
    # Имя хранилища = верхний каталог в архиве
    local name
    name=$(tar -tzf "$archive" 2>/dev/null | head -1 | cut -d/ -f1)
    if [[ -z "$name" ]]; then
        log_error "Не удалось прочитать имя хранилища из архива"
        return 1
    fi

    echo ""
    echo "  Архив:      $(basename "$archive")"
    echo "  Хранилище:  ${name}"
    local target="${REPO_DIR}/${name}"
    if [[ -e "$target" ]]; then
        echo ""
        log_warn "Хранилище '${name}' уже существует и БУДЕТ ЗАМЕНЕНО"
        read -rp "  Введите '${name}' для подтверждения замены: " confirm
        if [[ "$confirm" != "$name" ]]; then
            log_warn "Отменено"
            return
        fi
    fi

    # Останавливаем службу
    local was_active=0
    if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
        was_active=1
        log_step "Остановка службы..."
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
        sleep 1
    fi

    # Если каталог уже есть — переименовываем как .pre-restore.<ts>, чтобы откатить
    local rollback_dir=""
    if [[ -e "$target" ]]; then
        rollback_dir="${target}.pre-restore.$(date +%s)"
        mv "$target" "$rollback_dir"
    fi

    log_step "Распаковка архива..."
    if ! tar -xzf "$archive" -C "$REPO_DIR" 2>/tmp/crserver-tar.log; then
        log_error "Ошибка распаковки:"
        tail -5 /tmp/crserver-tar.log | sed 's/^/    /'
        rm -f /tmp/crserver-tar.log
        # Откат
        if [[ -n "$rollback_dir" ]]; then
            log_warn "Восстанавливаю предыдущее состояние..."
            rm -rf "$target" 2>/dev/null || true
            mv "$rollback_dir" "$target"
        fi
        if [[ $was_active -eq 1 ]]; then
            systemctl start ${SERVICE_NAME} 2>/dev/null || true
        fi
        return 1
    fi
    rm -f /tmp/crserver-tar.log

    detect_1c_user
    if [[ -n "$SVC_USER" && -n "$SVC_GROUP" ]]; then
        chown -R "${SVC_USER}:${SVC_GROUP}" "$target"
    fi

    log_info "Восстановлено: ${name}"
    if [[ -n "$rollback_dir" ]]; then
        echo "  Прежний вариант сохранён: ${rollback_dir}"
        echo "  Удалите его вручную, если новый бэкап работает корректно."
    fi

    if [[ $was_active -eq 1 ]]; then
        systemctl start ${SERVICE_NAME} 2>/dev/null || \
            log_warn "Служба не стартовала — проверьте journalctl"
    fi
}

do_repo_check() {
    local repo_chosen=""
    _select_repo_interactive || return
    local name="$repo_chosen"
    local dir="${REPO_DIR}/${name}"
    local issues=0

    echo ""
    echo "  Проверка хранилища '${name}'"
    echo "  ─────────────────────────────────────────────"

    detect_1c_user
    local owner
    owner=$(stat -c '%U:%G' "$dir" 2>/dev/null || echo "?")
    if [[ "$owner" == "${SVC_USER}:${SVC_GROUP}" ]]; then
        log_info "Владелец: ${owner}"
    else
        log_warn "Владелец: ${owner} (ожидается ${SVC_USER}:${SVC_GROUP})"
        issues=$((issues + 1))
    fi

    local mode
    mode=$(stat -c '%a' "$dir" 2>/dev/null || echo "?")
    if [[ "$mode" =~ ^[67][05][05]$ ]]; then
        log_info "Права: ${mode}"
    else
        log_warn "Права: ${mode} (рекомендуется 750/700)"
    fi

    if repo_looks_initialized "$dir"; then
        log_info "Структура: похоже на инициализированное хранилище"
    else
        log_warn "Структура: пусто/не инициализировано"
        echo "    Подключитесь конфигуратором и создайте хранилище:"
        echo "      Конфигурация → Хранилище конфигурации → Создать"
        issues=$((issues + 1))
    fi

    # Чужие файлы внутри (часто признак mv от другого пользователя)
    local foreign
    foreign=$(find "$dir" ! -user "$SVC_USER" 2>/dev/null | head -3)
    if [[ -n "$foreign" ]]; then
        log_warn "Найдены файлы НЕ принадлежащие ${SVC_USER}:"
        echo "$foreign" | sed 's/^/    /'
        echo "    Исправить: chown -R ${SVC_USER}:${SVC_GROUP} ${dir}"
        issues=$((issues + 1))
    fi

    # Lock-файлы (могут остаться от аварийного завершения)
    local locks
    locks=$(find "$dir" -maxdepth 2 -name "*.lck" -o -name "*.lock" 2>/dev/null | head -3)
    if [[ -n "$locks" ]]; then
        log_warn "Найдены lock-файлы:"
        echo "$locks" | sed 's/^/    /'
        echo "    Если служба остановлена — можно удалить вручную."
    fi

    echo ""
    if [[ $issues -eq 0 ]]; then
        log_info "Проблем не обнаружено"
    else
        log_warn "Обнаружено проблем: ${issues}"
    fi
}

# ============================================================================
#  УПРАВЛЕНИЕ ДОСТУПОМ (ФАЙРВОЛ)
# ============================================================================

# ──────────────────────────────────────────────────────────────────────────
# МОДЕЛЬ ЦЕПОЧКИ:
#   1. ACCEPT loopback (всегда)
#   2..N-1. ACCEPT для разрешённых IP/подсетей (добавляются пользователем)
#   N.  ПОЛИСИ-ПРАВИЛО (последнее):
#         ACCEPT (открытый режим)  — порт открыт всем
#         DROP   (whitelist режим) — пускаем только разрешённых
#
# Все вставки IP выполняются ПЕРЕД полиси-правилом.
# Подсчёт правил для индекса вставки берётся через -S (reliable) и пропускает
# заголовочные строки.
# ──────────────────────────────────────────────────────────────────────────

setup_firewall_chain() {
    iptables -N "$IPTABLES_CHAIN" 2>/dev/null || iptables -F "$IPTABLES_CHAIN"
    iptables -A "$IPTABLES_CHAIN" -s 127.0.0.1 -j ACCEPT
    # По умолчанию — открытый режим: финальное правило ACCEPT
    iptables -A "$IPTABLES_CHAIN" -j ACCEPT
    iptables -C INPUT -p tcp --dport "$REPO_PORT" -j "$IPTABLES_CHAIN" 2>/dev/null || \
        iptables -A INPUT -p tcp --dport "$REPO_PORT" -j "$IPTABLES_CHAIN"
    save_iptables
}

ensure_firewall_chain() {
    if ! iptables -L "$IPTABLES_CHAIN" -n &>/dev/null; then
        setup_firewall_chain
        return
    fi
    iptables -C INPUT -p tcp --dport "$REPO_PORT" -j "$IPTABLES_CHAIN" 2>/dev/null || \
        iptables -A INPUT -p tcp --dport "$REPO_PORT" -j "$IPTABLES_CHAIN"
}

cleanup_firewall() {
    iptables -D INPUT -p tcp --dport "$REPO_PORT" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -X "$IPTABLES_CHAIN" 2>/dev/null || true
    save_iptables
}

save_iptables() {
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save > /dev/null 2>&1 || true
    fi
}

# Возвращает количество правил в цепочке (по выводу -S, без -N строки)
chain_rule_count() {
    iptables -S "$IPTABLES_CHAIN" 2>/dev/null | grep -c '^-A ' || true
}

# Возвращает текущий полиси-режим: "whitelist" | "open" | "unknown"
current_policy_mode() {
    local last
    last=$(iptables -S "$IPTABLES_CHAIN" 2>/dev/null | grep '^-A ' | tail -1 || true)
    if [[ "$last" == *"-j DROP"* ]]; then
        echo "whitelist"
    elif [[ "$last" == "-A $IPTABLES_CHAIN -j ACCEPT" ]]; then
        echo "open"
    else
        echo "unknown"
    fi
}

# Заменяет финальное полиси-правило (DROP <-> ACCEPT-all)
set_policy_mode() {
    local mode="$1"  # whitelist | open
    ensure_firewall_chain

    # Удаляем все возможные финальные полиси-правила
    iptables -D "$IPTABLES_CHAIN" -j ACCEPT 2>/dev/null || true
    iptables -D "$IPTABLES_CHAIN" -j DROP   2>/dev/null || true

    case "$mode" in
        whitelist) iptables -A "$IPTABLES_CHAIN" -j DROP ;;
        open)      iptables -A "$IPTABLES_CHAIN" -j ACCEPT ;;
    esac
    save_iptables
}

do_access_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Управление доступом (файрвол)"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""

        local mode
        mode=$(current_policy_mode)
        echo -n "  Режим: "
        case "$mode" in
            whitelist) echo -e "${YELLOW}БЕЛЫЙ СПИСОК${NC} (доступ только для разрешённых IP)" ;;
            open)      echo -e "${GREEN}ОТКРЫТЫЙ${NC} (порт ${REPO_PORT} доступен всем)" ;;
            *)         echo -e "${RED}не настроен${NC} (создайте через установку)" ;;
        esac

        echo ""
        echo "  Правила для порта ${REPO_PORT}:"
        echo "  ─────────────────────────────────────────────"

        if iptables -L "$IPTABLES_CHAIN" -n --line-numbers 2>/dev/null | grep -qE '^[0-9]+ +(ACCEPT|DROP)'; then
            local line num action src color desc
            while IFS= read -r line; do
                # колонки: num target prot opt source destination ...
                num=$(awk '{print $1}'   <<< "$line")
                action=$(awk '{print $2}' <<< "$line")
                src=$(awk '{print $5}'    <<< "$line")
                color="${GREEN}"
                [[ "$action" == "DROP" ]] && color="${RED}"
                desc="$src"
                [[ "$src" == "0.0.0.0/0" ]] && desc="ВСЕ"
                echo -e "    [${num}] ${color}${action}${NC}  ←  ${desc}"
            done < <(iptables -L "$IPTABLES_CHAIN" -n --line-numbers 2>/dev/null | grep -E '^[0-9]+ +(ACCEPT|DROP)')
        else
            echo "    (цепочка не создана — выполните установку)"
        fi

        echo ""
        echo "  1) Добавить разрешённый IP"
        echo "  2) Добавить разрешённую подсеть"
        echo "  3) Включить режим белого списка (заблокировать всех остальных)"
        echo "  4) Открыть порт для всех (снять ограничения)"
        echo "  5) Удалить правило по номеру (см. [N] выше)"
        echo "  6) Показать мой внешний IP (curl ifconfig.me)"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1)
                read -rp "  IP-адрес: " ip
                if validate_ip "$ip"; then
                    add_allowed_ip "$ip"
                    log_info "IP $ip добавлен в разрешённые"
                else
                    log_error "Некорректный IP-адрес"
                fi
                ;;
            2)
                read -rp "  Подсеть (например 192.168.1.0/24): " subnet
                if [[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                    add_allowed_ip "$subnet"
                    log_info "Подсеть $subnet добавлена"
                else
                    log_error "Некорректный формат подсети"
                fi
                ;;
            3)
                echo ""
                log_warn "Это заблокирует все подключения, кроме явно разрешённых IP!"
                read -rp "  Продолжить? (y/N): " answer
                if [[ "$answer" =~ ^[Yy]$ ]]; then
                    enable_whitelist_mode
                    log_info "Режим белого списка включён"
                fi
                ;;
            4)
                set_policy_mode open
                log_info "Порт ${REPO_PORT} открыт для всех"
                ;;
            5)
                read -rp "  Номер правила для удаления: " rule_num
                if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
                    ensure_firewall_chain
                    if iptables -D "$IPTABLES_CHAIN" "$rule_num" 2>/dev/null; then
                        save_iptables
                        log_info "Правило #${rule_num} удалено"
                    else
                        log_error "Не удалось удалить правило #${rule_num}"
                    fi
                else
                    log_error "Номер должен быть числом"
                fi
                ;;
            6)
                echo ""
                echo -n "  Внешний IP: "
                curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "(не удалось определить)"
                echo ""
                echo ""
                read -rp "  Нажмите Enter..." _
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && return 0
    return 1
}

add_allowed_ip() {
    local ip="$1"
    ensure_firewall_chain

    if iptables -C "$IPTABLES_CHAIN" -s "$ip" -j ACCEPT 2>/dev/null; then
        log_warn "IP $ip уже в списке"
        return
    fi

    # Вставляем перед последним правилом (полиси-правилом).
    local total
    total=$(chain_rule_count)
    if [[ $total -ge 1 ]]; then
        iptables -I "$IPTABLES_CHAIN" "$total" -s "$ip" -j ACCEPT
    else
        iptables -A "$IPTABLES_CHAIN" -s "$ip" -j ACCEPT
    fi

    save_iptables
}

enable_whitelist_mode() {
    ensure_firewall_chain

    if [[ "$(current_policy_mode)" == "whitelist" ]]; then
        log_warn "Режим белого списка уже включён"
        return
    fi

    set_policy_mode whitelist
}

# ============================================================================
#  БЭКАП / ВОССТАНОВЛЕНИЕ
# ============================================================================

do_backup_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Бэкап и восстановление"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""

        local backup_files=()
        if [[ -d "$BACKUP_DIR" ]]; then
            local f
            for f in "$BACKUP_DIR"/*.tar.gz; do
                [[ -f "$f" ]] && backup_files+=("$f")
            done
        fi

        if [[ ${#backup_files[@]} -gt 0 ]]; then
            echo "  Существующие бэкапы:"
            echo "  ─────────────────────────────────────────────"
            local idx=0 size
            for f in "${backup_files[@]}"; do
                idx=$((idx + 1))
                size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
                echo "    ${idx}) $(basename "$f")  [${size:-?}]"
            done
            echo ""
        else
            echo "  Бэкапов пока нет"
            echo ""
        fi

        echo "  1) Создать бэкап хранилищ"
        echo "  2) Восстановить из бэкапа"
        echo "  3) Настроить автоматический бэкап (cron)"
        echo "  4) Удалить старые бэкапы (по возрасту)"
        echo "  5) Удалить бэкап по номеру"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1) do_backup; read -rp "  Нажмите Enter..." _ ;;
            2) do_restore; read -rp "  Нажмите Enter..." _ ;;
            3) do_setup_cron_backup; read -rp "  Нажмите Enter..." _ ;;
            4)
                read -rp "  Удалить бэкапы старше N дней [30]: " days
                days="${days:-30}"
                if ! [[ "$days" =~ ^[0-9]+$ ]] || (( days < 1 )); then
                    log_error "Срок должен быть положительным числом"
                else
                    if [[ -d "$BACKUP_DIR" ]]; then
                        find "$BACKUP_DIR" -maxdepth 1 -name "crserver_backup_*.tar.gz" -mtime +"$days" -delete 2>/dev/null
                        log_info "Бэкапы старше ${days} дней удалены"
                    else
                        log_warn "Каталог бэкапов не существует"
                    fi
                fi
                ;;
            5)
                if [[ ${#backup_files[@]} -eq 0 ]]; then
                    log_warn "Нет бэкапов для удаления"
                else
                    read -rp "  Номер бэкапа для удаления (или 0 для отмены): " num
                    if [[ "$num" == "0" || -z "$num" ]]; then
                        :
                    elif [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#backup_files[@]} )); then
                        local target="${backup_files[$((num - 1))]}"
                        echo ""
                        echo "  Удалить: $(basename "$target")?"
                        read -rp "  (y/N): " ans
                        if [[ "$ans" =~ ^[Yy]$ ]]; then
                            rm -f "$target"
                            log_info "Удалён: $(basename "$target")"
                        fi
                    else
                        log_error "Неверный номер"
                    fi
                fi
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

do_backup() {
    if [[ ! -d "$REPO_DIR" ]]; then
        log_error "Каталог хранилищ не существует: ${REPO_DIR}"
        return 1
    fi

    mkdir -p "$BACKUP_DIR"
    local timestamp backup_file
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_file="${BACKUP_DIR}/crserver_backup_${timestamp}.tar.gz"

    log_step "Создание бэкапа хранилищ..."
    if ! tar -czf "$backup_file" \
            -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")" \
            --ignore-failed-read 2>/tmp/crserver-tar.log; then
        log_error "Создание бэкапа не удалось:"
        tail -5 /tmp/crserver-tar.log | sed 's/^/    /'
        rm -f /tmp/crserver-tar.log "$backup_file"
        return 1
    fi
    rm -f /tmp/crserver-tar.log

    local size
    size=$(du -sh "$backup_file" 2>/dev/null | awk '{print $1}')
    log_info "Бэкап создан: ${backup_file} [${size:-?}]"
}

do_restore() {
    if [[ ! -d "$BACKUP_DIR" ]] || ! ls "$BACKUP_DIR"/*.tar.gz &>/dev/null; then
        log_warn "Нет доступных бэкапов в ${BACKUP_DIR}"
        return
    fi

    echo ""
    echo "  Доступные бэкапы:"
    local files=()
    local idx=0
    for f in "$BACKUP_DIR"/*.tar.gz; do
        idx=$((idx + 1))
        files+=("$f")
        echo "    ${idx}) $(basename "$f")"
    done

    echo ""
    read -rp "  Номер бэкапа: " num

    if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#files[@]} ]]; then
        local selected="${files[$((num - 1))]}"
        echo ""
        log_warn "Это перезапишет текущие хранилища в ${REPO_DIR}!"
        read -rp "  Продолжить? (y/N): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            local was_active=0
            if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
                was_active=1
            fi
            systemctl stop ${SERVICE_NAME} 2>/dev/null || true

            if ! tar -xzf "$selected" -C "$(dirname "$REPO_DIR")" 2>/tmp/crserver-tar.log; then
                log_error "Ошибка распаковки бэкапа:"
                tail -5 /tmp/crserver-tar.log | sed 's/^/    /'
                rm -f /tmp/crserver-tar.log
                # Пытаемся вернуть службу в исходное состояние
                if [[ $was_active -eq 1 ]]; then
                    systemctl start ${SERVICE_NAME} 2>/dev/null || true
                fi
                return 1
            fi
            rm -f /tmp/crserver-tar.log

            detect_1c_user
            if [[ -n "$SVC_USER" && -n "$SVC_GROUP" ]]; then
                chown -R "${SVC_USER}:${SVC_GROUP}" "$REPO_DIR"
            fi

            if [[ $was_active -eq 1 ]]; then
                if ! systemctl start ${SERVICE_NAME} 2>/dev/null; then
                    log_error "Служба не запустилась после восстановления — journalctl -u ${SERVICE_NAME}"
                fi
            fi
            log_info "Восстановлено из: $(basename "$selected")"
        fi
    else
        log_error "Неверный номер"
    fi
}

do_setup_cron_backup() {
    local cron_script="/usr/local/bin/crserver-backup.sh"
    local keep_days=30

    read -rp "  Хранить N дней [30]: " input_days
    if [[ -n "$input_days" ]]; then
        if [[ "$input_days" =~ ^[0-9]+$ ]] && (( input_days >= 1 )); then
            keep_days="$input_days"
        else
            log_error "Срок должен быть положительным числом"
            return
        fi
    fi

    cat > "$cron_script" << EOFCRON
#!/bin/bash
set -u
BACKUP_DIR="${BACKUP_DIR}"
REPO_DIR="${REPO_DIR}"
KEEP_DAYS=${keep_days}

mkdir -p "\$BACKUP_DIR"
timestamp=\$(date +%Y%m%d_%H%M%S)
log_file="\${BACKUP_DIR}/.last-backup.log"
if ! tar -czf "\${BACKUP_DIR}/crserver_backup_\${timestamp}.tar.gz" \\
        -C "\$(dirname "\$REPO_DIR")" "\$(basename "\$REPO_DIR")" \\
        --ignore-failed-read 2>"\$log_file"; then
    logger -t crserver-backup "FAILED at \${timestamp}, see \${log_file}"
    exit 1
fi
find "\$BACKUP_DIR" -maxdepth 1 -name "crserver_backup_*.tar.gz" -mtime +\${KEEP_DAYS} -delete 2>/dev/null
EOFCRON

    chmod +x "$cron_script"
    local cron_line="0 3 * * * ${cron_script}"
    (crontab -l 2>/dev/null | grep -F -v "$cron_script"; echo "$cron_line") | crontab -

    log_info "Автобэкап: ежедневно в 03:00, хранение ${keep_days} дней"
}

# ============================================================================
#  ИНСТРУМЕНТЫ
# ============================================================================

do_tools_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Инструменты"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""
        echo "  1) Информация о системе"
        echo "  2) Список хранилищ"
        echo "  3) Проверка подключения к порту"
        echo "  4) Дисковое пространство"
        echo "  5) Проверка открытых портов"
        echo "  6) Диагностика проблем"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1) echo ""; do_system_info; read -rp "  Нажмите Enter..." _ ;;
            2) echo ""; do_list_repos; read -rp "  Нажмите Enter..." _ ;;
            3)
                read -rp "  IP для проверки (Enter для localhost): " test_ip
                test_ip="${test_ip:-127.0.0.1}"
                echo ""
                if timeout 3 bash -c "echo >/dev/tcp/${test_ip}/${REPO_PORT}" 2>/dev/null; then
                    log_info "Порт ${REPO_PORT} на ${test_ip} доступен"
                else
                    log_error "Порт ${REPO_PORT} на ${test_ip} недоступен"
                fi
                read -rp "  Нажмите Enter..." _
                ;;
            4)
                echo ""
                echo "  Дисковое пространство:"
                echo "  ─────────────────────────────────────────────"
                df -h / | tail -1 | awk '{printf "    Диск:      %s из %s (использовано %s)\n", $3, $2, $5}'
                [[ -d "$REPO_DIR" ]]    && echo "    Хранилища: $(du -sh "$REPO_DIR" 2>/dev/null | awk '{print $1}')"
                [[ -d "$BACKUP_DIR" ]]  && echo "    Бэкапы:    $(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
                [[ -d "$PACKAGES_DIR" ]] && echo "    Пакеты:    $(du -sh "$PACKAGES_DIR" 2>/dev/null | awk '{print $1}')"
                echo ""
                read -rp "  Нажмите Enter..." _
                ;;
            5)
                echo ""
                echo "  Открытые порты 1С:"
                echo "  ─────────────────────────────────────────────"
                ss -tlnp | head -1
                ss -tlnp | grep -E "1542|1540|1541|1543" || echo "    (порты 1С не найдены)"
                echo ""
                read -rp "  Нажмите Enter..." _
                ;;
            6) echo ""; do_diagnose; read -rp "  Нажмите Enter..." _ ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

do_system_info() {
    detect_active_version
    detect_1c_user
    get_installed_versions
    get_available_versions

    local os_name
    os_name=$(lsb_release -ds 2>/dev/null || true)
    if [[ -z "$os_name" && -f /etc/os-release ]]; then
        os_name=$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/,"",$2); print $2}' /etc/os-release || true)
    fi
    echo "  Информация о системе"
    echo "  ─────────────────────────────────────────────"
    echo "    ОС:            ${os_name:-неизвестно}"
    echo "    Ядро:          $(uname -r)"
    echo "    Hostname:      $(hostname)"
    echo "    IP:            $(get_primary_ip)"
    echo ""
    echo "  1С:Предприятие"
    echo "  ─────────────────────────────────────────────"
    echo "    Активная:      ${ACTIVE_VERSION:-не установлена}"
    echo -n "    Установленные: "
    if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
        echo "${INSTALLED_VERSIONS[*]}"
    else
        echo "(нет)"
    fi
    echo -n "    Пакеты:        "
    if [[ ${#AVAILABLE_VERSIONS[@]} -gt 0 ]]; then
        echo "${AVAILABLE_VERSIONS[*]}"
    else
        echo "(нет)"
    fi
    echo "    Пользователь:  ${SVC_USER}:${SVC_GROUP:-?}"
    echo "    Порт:          ${REPO_PORT}"
    echo "    Каталог:       ${REPO_DIR}"
    echo ""

    echo "  Пакеты dpkg:"
    echo "  ─────────────────────────────────────────────"
    dpkg -l | grep 1c-enterprise | awk '{printf "    %-50s %s\n", $2, $3}' 2>/dev/null || echo "    (не установлены)"
    echo ""
}

do_list_repos() {
    echo "  Хранилища в ${REPO_DIR}:"
    echo "  ─────────────────────────────────────────────"

    if [[ ! -d "$REPO_DIR" ]]; then
        echo "    (каталог не существует)"
        return
    fi

    local found=0 ip_addr
    ip_addr=$(get_primary_ip)
    local dir name size
    for dir in "$REPO_DIR"/*/; do
        if [[ -d "$dir" ]]; then
            found=1
            name=$(basename "$dir")
            size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            echo "    ${name}  [${size:-?}]"
            echo "      → tcp://${ip_addr}:${REPO_PORT}/${name}"
            echo ""
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "    (пусто — создайте хранилище из конфигуратора 1С)"
        echo ""
        echo "    Адрес: tcp://${ip_addr}:${REPO_PORT}/<имя_хранилища>"
    fi
    echo ""
}

do_diagnose() {
    echo "  Диагностика"
    echo "  ─────────────────────────────────────────────"

    detect_active_version
    detect_1c_user
    get_installed_versions

    local issues=0

    # crserver
    if [[ -n "$ACTIVE_CRSERVER_BIN" && -f "$ACTIVE_CRSERVER_BIN" ]]; then
        log_info "crserver: $ACTIVE_CRSERVER_BIN"
    else
        log_error "crserver не найден"
        issues=$((issues + 1))
    fi

    # Фантом активной версии — юнит ссылается на удалённый бинарник
    if [[ "$ACTIVE_VERSION_PHANTOM" -eq 1 ]]; then
        log_error "Активная версия (${ACTIVE_VERSION}) — ФАНТОМ: бинарник ${ACTIVE_CRSERVER_BIN} удалён"
        if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
            echo "    → Запустите меню «Управление версиями» → Переключить — будет автофикс"
        else
            echo "    → Установите версию через «Управление версиями» → Установить"
        fi
        issues=$((issues + 1))
    fi

    # Установленные версии
    if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
        log_info "Установлено версий: ${#INSTALLED_VERSIONS[@]} (${INSTALLED_VERSIONS[*]})"
    else
        log_error "Нет установленных версий"
        issues=$((issues + 1))
    fi

    # Служба
    if [[ -f /etc/systemd/system/${SERVICE_NAME}.service ]]; then
        log_info "Файл службы существует"
    else
        log_error "Файл службы не найден"
        issues=$((issues + 1))
    fi

    if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
        log_info "Служба работает"
    else
        log_error "Служба не запущена"
        issues=$((issues + 1))
    fi

    # Порт
    if ss -tlnp | grep -q ":${REPO_PORT}"; then
        log_info "Порт ${REPO_PORT} слушается"
    else
        log_error "Порт ${REPO_PORT} не слушается"
        issues=$((issues + 1))
    fi

    # Права
    if [[ -d "$REPO_DIR" ]]; then
        local owner
        owner=$(stat -c '%U:%G' "$REPO_DIR" 2>/dev/null || echo "?")
        if [[ "$owner" == "${SVC_USER}:${SVC_GROUP}" ]]; then
            log_info "Права: ${owner}"
        else
            log_error "Права: ${owner} (ожидается ${SVC_USER}:${SVC_GROUP})"
            issues=$((issues + 1))
        fi
    else
        log_error "Каталог ${REPO_DIR} не существует"
        issues=$((issues + 1))
    fi

    # Каталог пакетов
    if [[ -d "$PACKAGES_DIR" ]]; then
        get_available_versions
        log_info "Каталог пакетов: ${PACKAGES_DIR} (${#AVAILABLE_VERSIONS[@]} версий)"
    else
        log_warn "Каталог пакетов не создан: ${PACKAGES_DIR}"
    fi

    # Локаль
    if locale -a 2>/dev/null | grep -q "ru_RU.utf8"; then
        log_info "Локаль ru_RU.UTF-8"
    else
        log_warn "Локаль ru_RU.UTF-8 не найдена"
        issues=$((issues + 1))
    fi

    # Диск
    local disk_usage
    disk_usage=$(df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%' || true)
    if [[ "$disk_usage" =~ ^[0-9]+$ ]]; then
        if [[ $disk_usage -lt 90 ]]; then
            log_info "Диск: ${disk_usage}%"
        else
            log_warn "Диск: ${disk_usage}% — мало места!"
            issues=$((issues + 1))
        fi
    else
        log_warn "Не удалось определить занятость диска"
    fi

    echo ""
    if [[ $issues -eq 0 ]]; then
        log_info "Проблем не обнаружено"
    else
        log_warn "Обнаружено проблем: ${issues}"
    fi
    echo ""
}

# ============================================================================
#  УСТАНОВКА / УДАЛЕНИЕ ИЗ СИСТЕМНОГО PATH
# ============================================================================

SYMLINK_NAME="crserver"
SYMLINK_PATH="/usr/local/bin/${SYMLINK_NAME}"

do_path_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Быстрый вызов (системный PATH)"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""

        echo -n "  Статус: "
        if [[ -L "$SYMLINK_PATH" ]]; then
            echo -e "${GREEN}установлено${NC}  ${SYMLINK_PATH} → $(readlink -f "$SYMLINK_PATH")"
        elif [[ -f "$SYMLINK_PATH" ]]; then
            echo -e "${GREEN}установлено${NC}  ${SYMLINK_PATH} (копия)"
        else
            echo -e "${YELLOW}не установлено${NC}"
        fi

        echo ""
        echo "  1) Добавить в PATH (sudo ${SYMLINK_NAME})"
        echo "  2) Удалить из PATH"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1) do_path_install; read -rp "  Нажмите Enter..." _ ;;
            2) do_path_uninstall; read -rp "  Нажмите Enter..." _ ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

do_path_install() {
    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    if [[ "$script_path" == "$SYMLINK_PATH" ]]; then
        log_info "Уже установлено как '${SYMLINK_NAME}'"
        return
    fi

    if [[ -L "$SYMLINK_PATH" || -f "$SYMLINK_PATH" ]]; then
        read -rp "  ${SYMLINK_PATH} уже существует. Перезаписать? (y/N): " answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            return
        fi
        rm -f "$SYMLINK_PATH"
    fi

    chmod +x "$script_path"
    ln -s "$script_path" "$SYMLINK_PATH"

    log_info "Установлено: ${SYMLINK_PATH} → ${script_path}"
    echo ""
    echo "  Вызов: sudo ${SYMLINK_NAME}"
}

do_path_uninstall() {
    if [[ -L "$SYMLINK_PATH" || -f "$SYMLINK_PATH" ]]; then
        rm -f "$SYMLINK_PATH"
        log_info "Удалено: ${SYMLINK_PATH}"
    else
        log_warn "Команда '${SYMLINK_NAME}' не найдена в PATH"
    fi
}

# ============================================================================
#  ОБНОВЛЕНИЕ СКРИПТА (self-update)
# ============================================================================

# Извлекает значение SCRIPT_VERSION="..." из файла, не выполняя его
extract_version() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    awk -F'"' '/^SCRIPT_VERSION=/ {print $2; exit}' "$file"
}

# Сравнивает две semver-подобные строки. Возвращает:
#   0 — равны, 1 — A > B, 2 — A < B
version_compare() {
    local a="$1" b="$2"
    [[ "$a" == "$b" ]] && return 0
    local ia ib
    IFS='.' read -ra ia <<< "$a"
    IFS='.' read -ra ib <<< "$b"
    local len=${#ia[@]}
    (( ${#ib[@]} > len )) && len=${#ib[@]}
    local i ai bi
    for (( i = 0; i < len; i++ )); do
        ai="${ia[i]:-0}"; bi="${ib[i]:-0}"
        # Числовая часть (для нечисленных хвостов вроде -beta берём только цифры в начале)
        ai="${ai%%[!0-9]*}"; bi="${bi%%[!0-9]*}"
        ai="${ai:-0}"; bi="${bi:-0}"
        if (( 10#$ai > 10#$bi )); then return 1; fi
        if (( 10#$ai < 10#$bi )); then return 2; fi
    done
    return 0
}

# Скачивает удалённый скрипт во временный файл. echo'ит путь к файлу.
# raw.githubusercontent.com отдаёт ответ через Fastly CDN с TTL 5 минут —
# без обхода кэша свежепушеные версии до 5 минут видны как старые.
# Защита: query-параметр с timestamp + заголовки no-cache/pragma.
download_remote_script() {
    if ! command -v curl >/dev/null 2>&1; then
        log_error "Для обновления нужен curl: apt-get install curl" >&2
        return 1
    fi
    local tmp
    tmp=$(mktemp /tmp/crserver-manager.new.XXXXXX) || return 1
    local cache_buster="?_=$(date +%s)"
    local http_code
    http_code=$(curl -fsSL --max-time 30 \
        -H 'Cache-Control: no-cache' \
        -H 'Pragma: no-cache' \
        -o "$tmp" -w '%{http_code}' \
        "${UPDATE_URL}${cache_buster}" 2>/dev/null || echo "000")
    if [[ "$http_code" != "200" ]] || [[ ! -s "$tmp" ]]; then
        log_error "Не удалось скачать обновление (HTTP ${http_code}) с ${UPDATE_URL}" >&2
        rm -f "$tmp"
        return 1
    fi
    echo "$tmp"
}

# Печатает «текущая версия / удалённая версия» и возвращает:
#   0 — обновление доступно, 1 — уже актуально, 2 — ошибка
do_self_update_check() {
    log_step "Проверка обновлений..."
    echo "  Источник: ${UPDATE_URL}"
    local tmp
    tmp=$(download_remote_script) || return 2

    local remote_ver
    remote_ver=$(extract_version "$tmp" || true)
    rm -f "$tmp"

    if [[ -z "$remote_ver" ]]; then
        log_error "Не удалось определить версию в удалённом скрипте"
        return 2
    fi

    echo "  Текущая версия:  ${SCRIPT_VERSION}"
    echo "  В репозитории:   ${remote_ver}"

    local cmp
    set +e
    version_compare "$remote_ver" "$SCRIPT_VERSION"; cmp=$?
    set -e

    case $cmp in
        0) log_info "Установлена актуальная версия"; return 1 ;;
        1) log_info "Доступно обновление"; return 0 ;;
        2) log_warn "Локальная версия новее, чем в репозитории"; return 1 ;;
    esac
}

# Выполняет обновление. Аргумент: "force" — пропускает запрос подтверждения
# и работает даже если версии равны (полезно при ручном hotfix).
do_self_update() {
    local force="${1:-}"

    # Если скрипт запущен через симлинк (например, /usr/local/bin/crserver →
    # /root/crserver-manager.sh) — обновляем РЕАЛЬНЫЙ файл, а не симлинк,
    # иначе mv заменит симлинк обычным файлом и сломает раскладку.
    local invoked_path script_path
    invoked_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    if [[ -L "$invoked_path" ]]; then
        script_path=$(readlink -f "$invoked_path")
        log_info "Запущено через симлинк: ${invoked_path}"
        log_info "Обновляю целевой файл:    ${script_path}"
    else
        script_path="$invoked_path"
    fi

    if [[ ! -w "$script_path" ]]; then
        log_error "Нет прав на запись в ${script_path}"
        return 1
    fi

    log_step "Скачивание ${UPDATE_URL}..."
    local tmp
    tmp=$(download_remote_script) || return 1

    local remote_ver
    remote_ver=$(extract_version "$tmp" || true)
    if [[ -z "$remote_ver" ]]; then
        log_error "В скачанном файле нет SCRIPT_VERSION — обновление отменено"
        rm -f "$tmp"
        return 1
    fi

    # Проверка синтаксиса перед заменой
    if ! bash -n "$tmp" 2>/tmp/crserver-update-syntax.log; then
        log_error "Скачанный скрипт содержит синтаксические ошибки:"
        sed 's/^/    /' /tmp/crserver-update-syntax.log
        rm -f "$tmp" /tmp/crserver-update-syntax.log
        return 1
    fi
    rm -f /tmp/crserver-update-syntax.log

    echo "  Текущая версия:  ${SCRIPT_VERSION}"
    echo "  Новая версия:    ${remote_ver}"
    echo "  Целевой файл:    ${script_path}"

    local cmp
    set +e
    version_compare "$remote_ver" "$SCRIPT_VERSION"; cmp=$?
    set -e

    if [[ "$force" != "force" ]]; then
        case $cmp in
            0) log_info "Уже актуальная версия. Используйте --force для принудительной замены."
               rm -f "$tmp"; return 0 ;;
            2) log_warn "Локальная версия НОВЕЕ удалённой. Используйте --force для отката."
               rm -f "$tmp"; return 0 ;;
        esac

        echo ""
        read -rp "  Установить новую версию? (Y/n): " answer
        if [[ "$answer" =~ ^[Nn]$ ]]; then
            rm -f "$tmp"
            log_warn "Обновление отменено"
            return 0
        fi
    fi

    # Бэкап текущего файла рядом с ним
    local backup_path="${script_path}.bak.$(date +%Y%m%d_%H%M%S)"
    if ! cp -p "$script_path" "$backup_path"; then
        log_error "Не удалось создать резервную копию"
        rm -f "$tmp"
        return 1
    fi
    log_info "Резервная копия: ${backup_path}"

    # Сохраняем биты прав (rwxr-xr-x как у Edit, но возьмём текущие)
    local mode
    mode=$(stat -c '%a' "$script_path" 2>/dev/null || echo "755")

    # Атомарная замена через mv в пределах одного раздела
    if ! mv -f "$tmp" "$script_path"; then
        log_error "Не удалось заменить файл — восстанавливаю из бэкапа"
        cp -p "$backup_path" "$script_path" || true
        rm -f "$tmp"
        return 1
    fi
    chmod "$mode" "$script_path"

    log_info "Обновлено: ${SCRIPT_VERSION} → ${remote_ver}"
    echo ""
    echo -e "  ${YELLOW}Перезапустите скрипт, чтобы изменения вступили в силу:${NC}"
    echo "    sudo $script_path"
    return 0
}

do_update_menu() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "  Обновление скрипта"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Текущая версия: ${SCRIPT_VERSION}"
    echo "  Источник:       ${UPDATE_URL}"
    echo ""
    echo "  1) Проверить наличие обновлений"
    echo "  2) Обновить (с подтверждением)"
    echo "  3) Обновить принудительно (--force, перезаписать любую версию)"
    echo ""
    echo "  0) ← Назад"
    echo ""
    read -rp "  Выберите: " choice

    case $choice in
        1) do_self_update_check || true; read -rp "  Нажмите Enter..." _ ;;
        2) do_self_update;        read -rp "  Нажмите Enter..." _ ;;
        3) do_self_update force;  read -rp "  Нажмите Enter..." _ ;;
        0) return ;;
        *) log_warn "Неверный выбор"; sleep 1 ;;
    esac
}

# ============================================================================
#  СПРАВКА
# ============================================================================

do_help() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "  Справка — crserver-manager.sh v${SCRIPT_VERSION}"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Использование:"
    echo "    sudo ./crserver-manager.sh              интерактивное меню"
    echo "    sudo ./crserver-manager.sh install      полная установка"
    echo "    sudo ./crserver-manager.sh uninstall    полное удаление"
    echo "    sudo ./crserver-manager.sh start        запуск службы"
    echo "    sudo ./crserver-manager.sh stop         остановка"
    echo "    sudo ./crserver-manager.sh restart      перезапуск"
    echo "    sudo ./crserver-manager.sh status       статус"
    echo "    sudo ./crserver-manager.sh logs         логи (последние 50)"
    echo "    sudo ./crserver-manager.sh backup       создать бэкап"
    echo "    sudo ./crserver-manager.sh diagnose     диагностика"
    echo "    sudo ./crserver-manager.sh versions     список версий"
    echo "    sudo ./crserver-manager.sh path-install добавить в PATH"
    echo "    sudo ./crserver-manager.sh path-remove  удалить из PATH"
    echo "    sudo ./crserver-manager.sh repo list           список хранилищ"
    echo "    sudo ./crserver-manager.sh repo create <имя>   создать хранилище"
    echo "    sudo ./crserver-manager.sh repo delete <имя>   удалить хранилище"
    echo "    sudo ./crserver-manager.sh repo backup <имя>   бэкап хранилища"
    echo "    sudo ./crserver-manager.sh update       обновить скрипт"
    echo "      └─ update --check    проверить наличие обновлений"
    echo "      └─ update --force    обновить принудительно"
    echo "    sudo ./crserver-manager.sh version      версия скрипта"
    echo "    sudo ./crserver-manager.sh help         эта справка"
    echo ""
    echo "  Структура каталога пакетов:"
    echo "    ${PACKAGES_DIR}/"
    echo "    ├── 8.3.25.1560/"
    echo "    │   ├── 1c-enterprise-*-common_*.deb"
    echo "    │   ├── 1c-enterprise-*-server_*.deb"
    echo "    │   ├── 1c-enterprise-*-ws_*.deb"
    echo "    │   └── 1c-enterprise-*-crs_*.deb"
    echo "    ├── 8.3.26.XXXX/"
    echo "    │   └── ..."
    echo ""
    echo "  Подключение из конфигуратора 1С:"
    echo "    Конфигурация → Хранилище конфигурации →"
    echo "      Создать/Подключиться к хранилищу"
    echo "    Адрес: tcp://IP_СЕРВЕРА:ПОРТ/имя_хранилища"
    echo ""
    # Пауза только в интерактивном режиме (из меню), чтобы не задерживать
    # CLI-вызов `crserver help` в скриптах/пайпах.
    if [[ -t 0 && "${HELP_INTERACTIVE:-0}" -eq 1 ]]; then
        read -rp "  Нажмите Enter..." _
    fi
}

# ============================================================================
#  ГЛАВНОЕ МЕНЮ
# ============================================================================

main_menu() {
    while true; do
        load_config
        detect_active_version
        get_installed_versions
        # Авто-предложение фикса фантомной активной версии
        check_and_offer_phantom_fix

        local status_text status_color
        if [[ ${#INSTALLED_VERSIONS[@]} -eq 0 ]]; then
            status_text="НЕ УСТАНОВЛЕН"
            status_color="${RED}"
        elif systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
            status_text="РАБОТАЕТ"
            status_color="${GREEN}"
        else
            status_text="ОСТАНОВЛЕН"
            status_color="${YELLOW}"
        fi

        clear 2>/dev/null || true
        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  Сервер хранилища 1С:Предприятие${NC}   ${CYAN}v${SCRIPT_VERSION}${NC}"
        local active_label="${ACTIVE_VERSION:-—}"
        if [[ "$ACTIVE_VERSION_PHANTOM" -eq 1 ]]; then
            active_label="${ACTIVE_VERSION} ${RED}(фантом — бинарник отсутствует)${NC}"
        fi
        echo -e "  Версия 1С: ${active_label}   Статус: ${status_color}${status_text}${NC}"
        if [[ ${#INSTALLED_VERSIONS[@]} -gt 1 ]]; then
            echo -e "  Установлено: ${INSTALLED_VERSIONS[*]}"
        fi
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""
        echo "  1) Управление версиями"
        echo "  2) Управление службой"
        echo "  3) Настройки сервера"
        echo "  4) Хранилища конфигураций"
        echo "  5) Управление доступом (файрвол)"
        echo "  6) Бэкап и восстановление (всё целиком)"
        echo "  7) Инструменты"
        echo "  8) Быстрый вызов (PATH)"
        echo "  9) Обновление скрипта"
        echo " 10) Справка"
        echo ""
        echo "  0) Выход"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1)  do_version_menu ;;
            2)  do_service_menu ;;
            3)  do_settings_menu ;;
            4)  do_repo_menu ;;
            5)  do_access_menu ;;
            6)  do_backup_menu ;;
            7)  do_tools_menu ;;
            8)  do_path_menu ;;
            9)  do_update_menu ;;
            10) HELP_INTERACTIVE=1 do_help ;;
            0)  echo ""; exit 0 ;;
            *)  log_warn "Неверный выбор" ;;
        esac
    done
}

# ============================================================================
#  ТОЧКА ВХОДА: CLI-аргументы или интерактивное меню
# ============================================================================

check_root
load_config

case "${1:-}" in
    install)       do_full_install ;;
    uninstall)     do_full_uninstall ;;
    start)
        if systemctl start ${SERVICE_NAME}; then
            log_info "Запущен"
        else
            log_error "Ошибка запуска (journalctl -u ${SERVICE_NAME} -n 20)"
            exit 1
        fi
        ;;
    stop)
        if systemctl stop ${SERVICE_NAME}; then
            log_info "Остановлен"
        else
            log_error "Ошибка остановки"
            exit 1
        fi
        ;;
    restart)
        if systemctl restart ${SERVICE_NAME}; then
            log_info "Перезапущен"
        else
            log_error "Ошибка перезапуска (journalctl -u ${SERVICE_NAME} -n 20)"
            exit 1
        fi
        ;;
    status)
        if [[ ! -f /etc/systemd/system/${SERVICE_NAME}.service ]]; then
            log_warn "Служба не установлена"
            exit 1
        fi
        systemctl status ${SERVICE_NAME} --no-pager || true
        ss -tlnp 2>/dev/null | grep ":${REPO_PORT}" || true
        ;;
    logs)          journalctl -u ${SERVICE_NAME} -n 50 --no-pager ;;
    backup)        do_backup ;;
    diagnose)      do_diagnose ;;
    versions)
        detect_active_version
        get_installed_versions
        get_available_versions
        echo ""
        echo "  Активная:      ${ACTIVE_VERSION:-—}"
        echo -n "  Установленные: "
        [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]] && echo "${INSTALLED_VERSIONS[*]}" || echo "(нет)"
        echo -n "  Пакеты:        "
        [[ ${#AVAILABLE_VERSIONS[@]} -gt 0 ]] && echo "${AVAILABLE_VERSIONS[*]}" || echo "(нет)"
        echo ""
        ;;
    path-install)  do_path_install ;;
    path-remove)   do_path_uninstall ;;
    repo|repos)
        case "${2:-list}" in
            list)
                local repos=()
                get_repo_list repos
                if [[ ${#repos[@]} -eq 0 ]]; then
                    echo "(хранилищ нет)"
                else
                    printf '%s\n' "${repos[@]}"
                fi
                ;;
            create)
                if [[ -z "${3:-}" ]]; then
                    log_error "Использование: $0 repo create <имя>"
                    exit 1
                fi
                if ! validate_repo_name "$3"; then
                    log_error "Недопустимое имя"
                    exit 1
                fi
                detect_1c_user
                if [[ -z "$SVC_USER" || -z "$SVC_GROUP" ]]; then
                    log_error "Не определён пользователь usr1cv8"
                    exit 1
                fi
                local d="${REPO_DIR}/$3"
                if [[ -e "$d" ]]; then
                    log_error "Уже существует: $d"
                    exit 1
                fi
                mkdir -p "$d"
                chown "${SVC_USER}:${SVC_GROUP}" "$d"
                chmod 750 "$d"
                log_info "Создано: $d"
                ;;
            delete)
                if [[ -z "${3:-}" ]]; then
                    log_error "Использование: $0 repo delete <имя>"
                    exit 1
                fi
                local d="${REPO_DIR}/$3"
                if [[ ! -d "$d" ]]; then
                    log_error "Не найдено: $d"
                    exit 1
                fi
                local was_active=0
                if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
                    was_active=1
                    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
                    sleep 1
                fi
                rm -rf "$d" && log_info "Удалено: $3"
                if [[ $was_active -eq 1 ]]; then
                    systemctl start ${SERVICE_NAME} 2>/dev/null || true
                fi
                ;;
            backup)
                if [[ -z "${3:-}" ]]; then
                    log_error "Использование: $0 repo backup <имя>"
                    exit 1
                fi
                local d="${REPO_DIR}/$3"
                if [[ ! -d "$d" ]]; then
                    log_error "Не найдено: $d"
                    exit 1
                fi
                mkdir -p "$BACKUP_DIR"
                local ts a
                ts=$(date +%Y%m%d_%H%M%S)
                a="${BACKUP_DIR}/repo_${3}_${ts}.tar.gz"
                if tar -czf "$a" -C "$REPO_DIR" "$3" 2>/dev/null; then
                    log_info "Бэкап: $a"
                else
                    log_error "tar не удался"
                    exit 1
                fi
                ;;
            *)
                log_error "Использование: $0 repo {list|create <имя>|delete <имя>|backup <имя>}"
                exit 1
                ;;
        esac
        ;;
    update)
        case "${2:-}" in
            ""|--yes|-y) do_self_update ;;
            --check)     do_self_update_check || true ;;
            --force)     do_self_update force ;;
            *)
                log_error "Неизвестный аргумент: $2"
                echo "  Использование: $0 update [--check|--force]"
                exit 1
                ;;
        esac
        ;;
    version|--version|-V)
        echo "crserver-manager.sh ${SCRIPT_VERSION}"
        ;;
    help|--help|-h) do_help ;;
    "")            main_menu ;;
    *)
        log_error "Неизвестная команда: $1"
        do_help
        exit 1
        ;;
esac