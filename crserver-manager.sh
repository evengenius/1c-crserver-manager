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
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
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

# Определяет активную версию (из systemd-службы)
detect_active_version() {
    ACTIVE_VERSION=""
    ACTIVE_CRSERVER_BIN=""

    if [[ -f /etc/systemd/system/${SERVICE_NAME}.service ]]; then
        local exec_line
        exec_line=$(grep "^ExecStart=" /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || true)
        if [[ -n "$exec_line" ]]; then
            ACTIVE_CRSERVER_BIN=$(echo "$exec_line" | sed 's/^ExecStart=//' | awk '{print $1}')
            ACTIVE_VERSION=$(echo "$ACTIVE_CRSERVER_BIN" | grep -oP '8\.3\.\d+\.\d+' || true)
        fi
    fi

    # Фоллбэк: ищем любой установленный crserver
    if [[ -z "$ACTIVE_VERSION" ]] && [[ -d /opt/1cv8/x86_64 ]]; then
        for dir in /opt/1cv8/x86_64/*/; do
            if [[ -f "${dir}crserver" ]]; then
                ACTIVE_CRSERVER_BIN="${dir}crserver"
                ACTIVE_VERSION=$(basename "$dir")
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
        for dir in "$PACKAGES_DIR"/*/; do
            [[ -d "$dir" ]] || continue
            local ver=$(basename "$dir")
            # Проверяем что внутри есть хотя бы crs-пакет
            if ls "$dir"/1c-enterprise-*-crs_*.deb &>/dev/null; then
                AVAILABLE_VERSIONS+=("$ver")
            fi
        done
    fi
}

# Проверяет наличие 4 пакетов в каталоге версии
validate_version_packages() {
    local ver="$1"
    local dir="${PACKAGES_DIR}/${ver}"
    local ok=1

    [[ -z "$(find "$dir" -maxdepth 1 -name '1c-enterprise-*-common_*.deb' ! -name '*-nls*' 2>/dev/null | head -1)" ]] && ok=0
    [[ -z "$(find "$dir" -maxdepth 1 -name '1c-enterprise-*-server_*.deb' ! -name '*-nls*' 2>/dev/null | head -1)" ]] && ok=0
    [[ -z "$(find "$dir" -maxdepth 1 -name '1c-enterprise-*-ws_*.deb'     ! -name '*-nls*' 2>/dev/null | head -1)" ]] && ok=0
    [[ -z "$(find "$dir" -maxdepth 1 -name '1c-enterprise-*-crs_*.deb'    ! -name '*-nls*' 2>/dev/null | head -1)" ]] && ok=0

    return $(( 1 - ok ))
}

# Определяем пользователя и группу 1С
detect_1c_user() {
    SVC_USER="usr1cv8"
    SVC_GROUP=""
    if id "$SVC_USER" &>/dev/null; then
        SVC_GROUP=$(id -gn "$SVC_USER")
    fi
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
            echo -e "${GREEN}${ACTIVE_VERSION}${NC}"
        else
            echo -e "${YELLOW}не установлена${NC}"
        fi

        # Установленные
        echo -n "  Установленные:    "
        if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
            local first=1
            for v in "${INSTALLED_VERSIONS[@]}"; do
                [[ $first -eq 0 ]] && echo -n ", "
                if [[ "$v" == "$ACTIVE_VERSION" ]]; then
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

    local COMMON_PKG=$(find "$pkg_dir" -maxdepth 1 -name "1c-enterprise-*-common_*.deb" ! -name "*-nls*" | head -1)
    local SERVER_PKG=$(find "$pkg_dir" -maxdepth 1 -name "1c-enterprise-*-server_*.deb" ! -name "*-nls*" | head -1)
    local WS_PKG=$(find "$pkg_dir" -maxdepth 1 -name "1c-enterprise-*-ws_*.deb" ! -name "*-nls*" | head -1)
    local CRS_PKG=$(find "$pkg_dir" -maxdepth 1 -name "1c-enterprise-*-crs_*.deb" ! -name "*-nls*" | head -1)

    echo "  Пакеты:"
    echo "    common: $(basename "$COMMON_PKG")"
    echo "    server: $(basename "$SERVER_PKG")"
    echo "    ws:     $(basename "$WS_PKG")"
    echo "    crs:    $(basename "$CRS_PKG")"
    echo ""

    dpkg -i "$COMMON_PKG" 2>&1 | tail -1 || true
    dpkg -i "$SERVER_PKG" 2>&1 | tail -1 || true
    dpkg -i "$WS_PKG"     2>&1 | tail -1 || true
    dpkg -i "$CRS_PKG"    2>&1 | tail -1 || true
    apt-get install -f -y -qq > /dev/null 2>&1 || true

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
            [[ ! "$answer" =~ ^[Yy]$ ]] && return
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

    # Если удалили активную — чистим службу
    detect_active_version
    if [[ "$ACTIVE_VERSION" == "$ver" || -z "$ACTIVE_VERSION" ]]; then
        get_installed_versions
        if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
            log_warn "Активная версия удалена. Переключитесь на другую через меню."
        else
            # Удаляем службу если версий не осталось
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

    if [[ ${#INSTALLED_VERSIONS[@]} -lt 2 ]]; then
        if [[ ${#INSTALLED_VERSIONS[@]} -eq 0 ]]; then
            log_warn "Нет установленных версий"
        else
            log_warn "Установлена только одна версия: ${INSTALLED_VERSIONS[0]}"
        fi
        read -rp "  Нажмите Enter..." _
        return
    fi

    echo ""
    echo "  Установленные версии:"
    local idx=0
    for v in "${INSTALLED_VERSIONS[@]}"; do
        idx=$((idx + 1))
        if [[ "$v" == "$ACTIVE_VERSION" ]]; then
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

        if [[ "$selected" == "$ACTIVE_VERSION" ]]; then
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

    log_step "Переключение на версию ${ver}..."

    # Останавливаем текущую службу
    systemctl stop ${SERVICE_NAME} 2>/dev/null || true

    # Пересоздаём службу с новой версией
    ACTIVE_VERSION="$ver"
    ACTIVE_CRSERVER_BIN="$new_bin"
    regenerate_service

    # Запускаем
    systemctl start ${SERVICE_NAME}
    sleep 2

    if systemctl is-active --quiet ${SERVICE_NAME}; then
        log_info "Переключено на версию ${ver} — служба запущена"
    else
        log_error "Служба не запустилась. Проверьте: journalctl -u ${SERVICE_NAME} -n 50"
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
    while IFS= read -r crs_file; do
        local ver=$(basename "$crs_file" | grep -oP '8\.3\.\d+\.\d+' || true)
        if [[ -n "$ver" ]]; then
            # Проверяем что нет дубликатов
            local dup=0
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

    for ver in "${found_versions[@]}"; do
        local dest="${PACKAGES_DIR}/${ver}"
        mkdir -p "$dest"

        local count=0
        for deb in "$source_dir"/1c-enterprise-${ver}-*.deb; do
            [[ -f "$deb" ]] || continue
            cp -v "$deb" "$dest/" 2>/dev/null
            count=$((count + 1))
        done

        log_info "Версия ${ver}: скопировано ${count} пакетов → ${dest}/"
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
    regenerate_service
    log_info "Служба создана"

    # --- 6. Файрвол ---
    log_step "Настройка файрвола..."
    setup_firewall_chain
    log_info "Файрвол настроен"

    # --- 7. Запуск ---
    log_step "Запуск сервера хранилища..."
    systemctl start ${SERVICE_NAME}
    sleep 2

    if systemctl is-active --quiet ${SERVICE_NAME}; then
        log_info "Сервер хранилища ЗАПУЩЕН"
    else
        log_error "Не удалось запустить. Проверьте: journalctl -u ${SERVICE_NAME} -n 50"
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
    IP_ADDR=$(hostname -I | awk '{print $1}')
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
            1) systemctl start ${SERVICE_NAME} && log_info "Запущен" || log_error "Ошибка запуска"; sleep 1 ;;
            2) systemctl stop ${SERVICE_NAME} && log_info "Остановлен" || log_error "Ошибка остановки" ;;
            3) systemctl restart ${SERVICE_NAME} && log_info "Перезапущен" || log_error "Ошибка"; sleep 1 ;;
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
    detect_active_version
    detect_1c_user

    local bin="${ACTIVE_CRSERVER_BIN}"
    local ver="${ACTIVE_VERSION}"

    if [[ -z "$bin" || ! -f "$bin" ]]; then
        log_error "crserver не найден. Сначала установите версию."
        return 1
    fi

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

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME} > /dev/null 2>&1
}

# ============================================================================
#  УПРАВЛЕНИЕ ДОСТУПОМ (ФАЙРВОЛ)
# ============================================================================

setup_firewall_chain() {
    iptables -N "$IPTABLES_CHAIN" 2>/dev/null || iptables -F "$IPTABLES_CHAIN"
    iptables -A "$IPTABLES_CHAIN" -s 127.0.0.1 -j ACCEPT
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

do_access_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Управление доступом (файрвол)"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""

        echo "  Текущие правила для порта ${REPO_PORT}:"
        echo "  ─────────────────────────────────────────────"

        if iptables -L "$IPTABLES_CHAIN" -n 2>/dev/null | grep -q "ACCEPT\|DROP"; then
            local idx=0
            while IFS= read -r line; do
                if [[ "$line" == *"ACCEPT"* || "$line" == *"DROP"* ]]; then
                    idx=$((idx + 1))
                    local src=$(echo "$line" | awk '{print $4}')
                    local action=$(echo "$line" | awk '{print $1}')
                    [[ "$src" == "0.0.0.0/0" ]] && src="ВСЕ"
                    local color="${GREEN}"
                    [[ "$action" == "DROP" ]] && color="${RED}"
                    echo -e "    ${idx}) ${color}${action}${NC}  ←  ${src}"
                fi
            done <<< "$(iptables -L "$IPTABLES_CHAIN" -n 2>/dev/null)"
        else
            echo "    (цепочка не создана — порт открыт по умолчанию)"
        fi

        echo ""
        echo "  1) Добавить разрешённый IP"
        echo "  2) Добавить разрешённую подсеть"
        echo "  3) Включить режим белого списка (заблокировать всех остальных)"
        echo "  4) Открыть порт для всех (снять ограничения)"
        echo "  5) Удалить правило по номеру"
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
                ensure_firewall_chain
                iptables -F "$IPTABLES_CHAIN" 2>/dev/null || true
                iptables -A "$IPTABLES_CHAIN" -s 127.0.0.1 -j ACCEPT
                iptables -A "$IPTABLES_CHAIN" -j ACCEPT
                save_iptables
                log_info "Порт ${REPO_PORT} открыт для всех"
                ;;
            5)
                read -rp "  Номер правила для удаления: " rule_num
                if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
                    ensure_firewall_chain
                    iptables -D "$IPTABLES_CHAIN" "$rule_num" 2>/dev/null && \
                        { save_iptables; log_info "Правило #${rule_num} удалено"; } || \
                        log_error "Не удалось удалить правило #${rule_num}"
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

    local num_rules
    num_rules=$(iptables -L "$IPTABLES_CHAIN" --line-numbers -n 2>/dev/null | tail -n +3 | wc -l)

    if [[ $num_rules -gt 0 ]]; then
        iptables -I "$IPTABLES_CHAIN" "$num_rules" -s "$ip" -j ACCEPT
    else
        iptables -A "$IPTABLES_CHAIN" -s "$ip" -j ACCEPT
    fi

    save_iptables
}

enable_whitelist_mode() {
    ensure_firewall_chain

    local has_drop
    has_drop=$(iptables -L "$IPTABLES_CHAIN" -n 2>/dev/null | grep -c "DROP.*0\.0\.0\.0/0" || true)

    if [[ "$has_drop" -gt 0 ]]; then
        log_warn "Режим белого списка уже включён"
        return
    fi

    while iptables -D "$IPTABLES_CHAIN" -s 0.0.0.0/0 -j ACCEPT 2>/dev/null; do :; done
    iptables -A "$IPTABLES_CHAIN" -j DROP
    save_iptables
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

        if [[ -d "$BACKUP_DIR" ]] && ls "$BACKUP_DIR"/*.tar.gz &>/dev/null; then
            echo "  Существующие бэкапы:"
            echo "  ─────────────────────────────────────────────"
            local idx=0
            for f in "$BACKUP_DIR"/*.tar.gz; do
                idx=$((idx + 1))
                local size=$(du -sh "$f" | awk '{print $1}')
                echo "    ${idx}) $(basename "$f")  [${size}]"
            done
            echo ""
        else
            echo "  Бэкапов пока нет"
            echo ""
        fi

        echo "  1) Создать бэкап хранилищ"
        echo "  2) Восстановить из бэкапа"
        echo "  3) Настроить автоматический бэкап (cron)"
        echo "  4) Удалить старые бэкапы"
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
                find "$BACKUP_DIR" -name "*.tar.gz" -mtime +"$days" -delete 2>/dev/null
                log_info "Бэкапы старше ${days} дней удалены"
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

do_backup() {
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/crserver_backup_${timestamp}.tar.gz"

    log_step "Создание бэкапа хранилищ..."
    tar -czf "$backup_file" \
        -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")" \
        --ignore-failed-read 2>/dev/null || true

    local size=$(du -sh "$backup_file" | awk '{print $1}')
    log_info "Бэкап создан: $backup_file [$size]"
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
            systemctl stop ${SERVICE_NAME} 2>/dev/null || true
            tar -xzf "$selected" -C "$(dirname "$REPO_DIR")" 2>/dev/null
            detect_1c_user
            chown -R "${SVC_USER}:${SVC_GROUP}" "$REPO_DIR"
            systemctl start ${SERVICE_NAME} 2>/dev/null || true
            log_info "Восстановлено из: $(basename "$selected")"
        fi
    else
        log_error "Неверный номер"
    fi
}

do_setup_cron_backup() {
    local cron_script="/usr/local/bin/crserver-backup.sh"

    cat > "$cron_script" << EOFCRON
#!/bin/bash
BACKUP_DIR="${BACKUP_DIR}"
REPO_DIR="${REPO_DIR}"
KEEP_DAYS=30

mkdir -p "\$BACKUP_DIR"
timestamp=\$(date +%Y%m%d_%H%M%S)
tar -czf "\${BACKUP_DIR}/crserver_backup_\${timestamp}.tar.gz" \\
    -C "\$(dirname "\$REPO_DIR")" "\$(basename "\$REPO_DIR")" \\
    --ignore-failed-read 2>/dev/null
find "\$BACKUP_DIR" -name "*.tar.gz" -mtime +\${KEEP_DAYS} -delete 2>/dev/null
EOFCRON

    chmod +x "$cron_script"
    local cron_line="0 3 * * * ${cron_script}"
    (crontab -l 2>/dev/null | grep -v "$cron_script"; echo "$cron_line") | crontab -

    log_info "Автобэкап: ежедневно в 03:00, хранение 30 дней"
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

    echo "  Информация о системе"
    echo "  ─────────────────────────────────────────────"
    echo "    ОС:            $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo "    Ядро:          $(uname -r)"
    echo "    Hostname:      $(hostname)"
    echo "    IP:            $(hostname -I | awk '{print $1}')"
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

    local found=0
    for dir in "$REPO_DIR"/*/; do
        if [[ -d "$dir" ]]; then
            found=1
            local name=$(basename "$dir")
            local size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            local ip_addr=$(hostname -I | awk '{print $1}')
            echo "    ${name}  [${size}]"
            echo "      → tcp://${ip_addr}:${REPO_PORT}/${name}"
            echo ""
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "    (пусто — создайте хранилище из конфигуратора 1С)"
        echo ""
        local ip_addr=$(hostname -I | awk '{print $1}')
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
        local owner=$(stat -c '%U:%G' "$REPO_DIR" 2>/dev/null)
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
    local disk_usage=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
    if [[ $disk_usage -lt 90 ]]; then
        log_info "Диск: ${disk_usage}%"
    else
        log_warn "Диск: ${disk_usage}% — мало места!"
        issues=$((issues + 1))
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
        [[ ! "$answer" =~ ^[Yy]$ ]] && return
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
#  СПРАВКА
# ============================================================================

do_help() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "  Справка — crserver-manager.sh"
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
}

# ============================================================================
#  ГЛАВНОЕ МЕНЮ
# ============================================================================

main_menu() {
    while true; do
        load_config
        detect_active_version
        get_installed_versions

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
        echo -e "${BOLD}  Сервер хранилища 1С:Предприятие${NC}"
        echo -e "  Версия: ${ACTIVE_VERSION:-—}   Статус: ${status_color}${status_text}${NC}"
        if [[ ${#INSTALLED_VERSIONS[@]} -gt 1 ]]; then
            echo -e "  Установлено: ${INSTALLED_VERSIONS[*]}"
        fi
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""
        echo "  1) Управление версиями"
        echo "  2) Управление службой"
        echo "  3) Настройки сервера"
        echo "  4) Управление доступом (файрвол)"
        echo "  5) Бэкап и восстановление"
        echo "  6) Инструменты"
        echo "  7) Быстрый вызов (PATH)"
        echo "  8) Справка"
        echo ""
        echo "  0) Выход"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1) do_version_menu ;;
            2) do_service_menu ;;
            3) do_settings_menu ;;
            4) do_access_menu ;;
            5) do_backup_menu ;;
            6) do_tools_menu ;;
            7) do_path_menu ;;
            8) do_help ;;
            0) echo ""; exit 0 ;;
            *) log_warn "Неверный выбор" ;;
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
    start)         systemctl start ${SERVICE_NAME} && log_info "Запущен" ;;
    stop)          systemctl stop ${SERVICE_NAME} && log_info "Остановлен" ;;
    restart)       systemctl restart ${SERVICE_NAME} && log_info "Перезапущен" ;;
    status)
        systemctl status ${SERVICE_NAME} --no-pager 2>/dev/null || log_warn "Служба не найдена"
        ss -tlnp | grep ":${REPO_PORT}" 2>/dev/null || true
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
    help|--help|-h) do_help ;;
    "")            main_menu ;;
    *)
        log_error "Неизвестная команда: $1"
        do_help
        exit 1
        ;;
esac