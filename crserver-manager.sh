#!/bin/bash
set -euo pipefail

# ============================================================================
#  crserver-manager.sh — Управление сервером хранилища конфигураций 1С
#  Debian 12 / Ubuntu 22.04+
#
#  v2.0.0 — мульти-инстанс архитектура
#
#  ОСНОВНЫЕ ИДЕИ:
#    * Один systemd-template /etc/systemd/system/crserver@.service
#      запускает несколько независимых инстансов crserver@<имя>.
#    * Каждый инстанс — отдельный конфиг /etc/1c-crserver/instances/<имя>.conf
#      со своими VERSION, REPO_DIR, REPO_PORT, LOG_DIR.
#    * Платформенные версии устанавливаются глобально в /opt/1cv8/x86_64/...
#      Несколько инстансов могут использовать одну и ту же версию.
#    * Файрвол: одна общая цепочка CRSERVER (глобальный whitelist) +
#      опциональные пер-инстанс цепочки CRSERVER-<имя> для тонких ACL.
#    * Бэкапы — общая директория /var/1c/backup. Имена включают имя инстанса.
#    * Файл /etc/1c-crserver/default-instance — указатель на инстанс по
#      умолчанию, используется при `crserver start|stop|backup|...` без -i.
#    * Миграция из v1.x: обнаружение старого crserver.service делается
#      пассивно; миграция запускается ТОЛЬКО через пункт меню «Инстансы».
#
#  Использование:
#    sudo ./crserver-manager.sh                       — интерактивное меню
#    sudo ./crserver-manager.sh install               — первичная установка
#    sudo ./crserver-manager.sh -i prod25 start       — на конкретном инстансе
#    sudo ./crserver-manager.sh instance list         — список инстансов
#    sudo ./crserver-manager.sh help                  — полная справка
# ============================================================================

# --- Версия скрипта ---
# При выпуске новой версии увеличить и закоммитить в репозиторий.
# Используется для проверки обновлений (см. do_self_update).
SCRIPT_VERSION="2.0.4"

# --- Источник обновлений ---
UPDATE_REPO="evengenius/1c-crserver-manager"
UPDATE_BRANCH="main"
UPDATE_URL="https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}/crserver-manager.sh"

# --- Конфигурация / пути ---
ETC_DIR="/etc/1c-crserver"
INSTANCES_DIR="${ETC_DIR}/instances"
DEFAULT_INSTANCE_FILE="${ETC_DIR}/default-instance"
LEGACY_CONFIG_FILE="${ETC_DIR}/crserver.conf"
LEGACY_SERVICE_FILE="/etc/systemd/system/crserver.service"
SERVICE_TEMPLATE_FILE="/etc/systemd/system/crserver@.service"

# Дефолты для НОВЫХ инстансов
DEFAULT_REPO_PORT=1542
DEFAULT_BACKUP_DIR="/var/1c/backup"

# Базовый префикс пути хранилищ/логов: /var/1c/repo-<name>, /var/log/1c/<name>
REPO_BASE="/var/1c"
LOG_BASE="/var/log/1c"

# Бэкап-каталог общий, поэтому константа
BACKUP_DIR="${DEFAULT_BACKUP_DIR}"

IPTABLES_CHAIN="CRSERVER"
PACKAGES_DIR_NAME="packages"

# --- Пути (вычисляются при запуске) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="${SCRIPT_DIR}/${PACKAGES_DIR_NAME}"

# --- Цвета ---
# NO_COLOR (https://no-color.org/) или не-tty stdout — отключаем escape-коды.
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
else
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
fi

# --- Логирование ---
log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${CYAN}[→]${NC} $1"; }

# Универсальное Y/N подтверждение.
#   confirm "Текст вопроса" [yes|no]   — второй аргумент задаёт умолчание
#   exit 0 — подтверждено, exit 1 — отказ
# Если stdin не tty — берём umolчание без запроса (для CI/автоматизации).
confirm() {
    local question="$1"
    local default="${2:-no}"
    local hint="(y/N)"
    [[ "$default" == "yes" ]] && hint="(Y/n)"
    if [[ ! -t 0 ]]; then
        [[ "$default" == "yes" ]]
        return $?
    fi
    local ans
    read -rp "  ${question} ${hint}: " ans
    if [[ -z "$ans" ]]; then
        [[ "$default" == "yes" ]]
        return $?
    fi
    [[ "$ans" =~ ^[Yy]$ ]]
}

# --- Контекст текущего инстанса (заполняется select_instance / instance_load) ---
SELECTED_INSTANCE=""
INST_NAME=""
INST_VERSION=""
INST_PORT=""
INST_REPO_DIR=""
INST_LOG_DIR=""

# --- Проверка root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Запустите скрипт от root: sudo $0"
        exit 1
    fi
}

# ============================================================================
#  ИНСТАНСЫ — БАЗОВЫЕ ОПЕРАЦИИ
# ============================================================================

# Валидация имени: ^[a-z][a-z0-9-]{0,31}$
instance_name_valid() {
    local name="$1"
    [[ -z "$name" ]] && return 1
    [[ ${#name} -gt 32 ]] && return 1
    [[ "$name" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 1
    return 0
}

# Заполняет глобальный массив INSTANCES именами всех существующих инстансов.
instance_list() {
    INSTANCES=()
    [[ -d "$INSTANCES_DIR" ]] || return 0
    local f name
    for f in "$INSTANCES_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .conf)
        instance_name_valid "$name" || continue
        INSTANCES+=("$name")
    done
}

instance_exists() {
    local name="$1"
    [[ -f "${INSTANCES_DIR}/${name}.conf" ]]
}

# Безопасный парсер: только KEY="VALUE" из белого списка ключей.
# Заполняет INST_* и INST_NAME.
instance_load() {
    local name="$1"
    local file="${INSTANCES_DIR}/${name}.conf"
    INST_NAME="$name"
    INST_VERSION=""
    INST_PORT=""
    INST_REPO_DIR=""
    INST_LOG_DIR=""

    if [[ ! -f "$file" ]]; then
        log_error "Конфиг инстанса не найден: $file"
        return 1
    fi

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=\"?([^\"]*)\"?[[:space:]]*$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            case "$key" in
                NAME)      ;; # информационно, имя берём из файла
                VERSION)   INST_VERSION="$val" ;;
                REPO_PORT) INST_PORT="$val" ;;
                REPO_DIR)  INST_REPO_DIR="$val" ;;
                LOG_DIR)   INST_LOG_DIR="$val" ;;
            esac
        fi
    done < "$file"

    if [[ -z "$INST_VERSION" || -z "$INST_PORT" || -z "$INST_REPO_DIR" || -z "$INST_LOG_DIR" ]]; then
        log_error "Конфиг инстанса '${name}' неполный (нужны VERSION, REPO_PORT, REPO_DIR, LOG_DIR)"
        return 1
    fi
    return 0
}

# Сохраняет конфиг инстанса. Берёт значения из INST_*.
instance_save() {
    local name="$1"
    if ! instance_name_valid "$name"; then
        log_error "Недопустимое имя инстанса: '${name}'"
        return 1
    fi
    if [[ -z "${INST_VERSION:-}" || -z "${INST_PORT:-}" || -z "${INST_REPO_DIR:-}" || -z "${INST_LOG_DIR:-}" ]]; then
        log_error "instance_save: не заполнены INST_* (VERSION/PORT/REPO_DIR/LOG_DIR)"
        return 1
    fi
    if ! [[ "$INST_PORT" =~ ^[0-9]+$ ]] || (( INST_PORT < 1 || INST_PORT > 65535 )); then
        log_error "Некорректный порт: '${INST_PORT}'"
        return 1
    fi
    local p
    for p in "$INST_REPO_DIR" "$INST_LOG_DIR"; do
        if [[ -z "$p" || "$p" != /* || "$p" == *$'\n'* ]]; then
            log_error "Некорректный путь: '${p}' (ожидается абсолютный путь)"
            return 1
        fi
    done
    # REPO_DIR и LOG_DIR должны быть разными — иначе chown/rm на одном
    # каталоге приведёт к катастрофе. Также LOG_DIR не должен быть
    # внутри REPO_DIR (и наоборот).
    if [[ "$INST_REPO_DIR" == "$INST_LOG_DIR" ]]; then
        log_error "REPO_DIR и LOG_DIR не могут совпадать"
        return 1
    fi
    if [[ "$INST_LOG_DIR" == "$INST_REPO_DIR"/* ]]; then
        log_error "LOG_DIR (${INST_LOG_DIR}) не может быть внутри REPO_DIR (${INST_REPO_DIR})"
        return 1
    fi
    if [[ "$INST_REPO_DIR" == "$INST_LOG_DIR"/* ]]; then
        log_error "REPO_DIR (${INST_REPO_DIR}) не может быть внутри LOG_DIR (${INST_LOG_DIR})"
        return 1
    fi

    mkdir -p "$INSTANCES_DIR"
    local file="${INSTANCES_DIR}/${name}.conf"
    cat > "$file" << EOF
# Конфигурация инстанса сервера хранилища 1С
# Файл читается systemd через EnvironmentFile=, поэтому имена совпадают
# с переменными окружения, ожидаемыми ExecStart-обёрткой.
NAME="${name}"
VERSION="${INST_VERSION}"
REPO_DIR="${INST_REPO_DIR}"
REPO_PORT="${INST_PORT}"
LOG_DIR="${INST_LOG_DIR}"
EOF
    chmod 644 "$file"
    return 0
}

# Возвращает строку "running"|"stopped"|"failed"|"phantom".
# phantom = в конфиге указана версия, бинарника которой нет в системе.
instance_status() {
    local name="$1"
    if ! instance_exists "$name"; then
        echo "missing"
        return 0
    fi
    local ver bin
    ver=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "${INSTANCES_DIR}/${name}.conf" 2>/dev/null || true)
    bin="/opt/1cv8/x86_64/${ver}/crserver"
    if [[ -n "$ver" && ! -f "$bin" ]]; then
        echo "phantom"
        return 0
    fi
    local active
    active=$(systemctl is-active "crserver@${name}.service" 2>/dev/null || true)
    case "$active" in
        active)        echo "running" ;;
        failed)        echo "failed" ;;
        *)             echo "stopped" ;;
    esac
}

# Имя инстанса по умолчанию.
# 1. Если задан /etc/1c-crserver/default-instance — берём оттуда (если такой инстанс существует).
# 2. Иначе если ровно один инстанс — он и есть дефолт.
# 3. Иначе — пусто.
instance_default() {
    if [[ -f "$DEFAULT_INSTANCE_FILE" ]]; then
        local name
        name=$(head -1 "$DEFAULT_INSTANCE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ -n "$name" ]] && instance_exists "$name"; then
            echo "$name"
            return 0
        fi
    fi
    instance_list
    if [[ ${#INSTANCES[@]} -eq 1 ]]; then
        echo "${INSTANCES[0]}"
        return 0
    fi
    echo ""
    return 0
}

instance_set_default() {
    local name="$1"
    if ! instance_exists "$name"; then
        log_error "Инстанс не существует: ${name}"
        return 1
    fi
    mkdir -p "$ETC_DIR"
    printf '%s\n' "$name" > "$DEFAULT_INSTANCE_FILE"
    chmod 644 "$DEFAULT_INSTANCE_FILE"
    return 0
}

# Интерактивный выбор инстанса. Заполняет SELECTED_INSTANCE.
# Если инстансов нет — ошибка. Если один — выбирает молча. Если несколько —
# подсказывает дефолтный (если есть), иначе спрашивает.
select_instance_interactive() {
    SELECTED_INSTANCE=""
    instance_list
    if [[ ${#INSTANCES[@]} -eq 0 ]]; then
        log_error "Нет ни одного инстанса. Создайте через меню «Инстансы» → «Создать»."
        return 1
    fi
    if [[ ${#INSTANCES[@]} -eq 1 ]]; then
        SELECTED_INSTANCE="${INSTANCES[0]}"
        return 0
    fi
    local def
    def=$(instance_default)
    echo ""
    echo "  Выберите инстанс:"
    local idx=0 n status_text mark
    for n in "${INSTANCES[@]}"; do
        idx=$((idx + 1))
        status_text=$(instance_status "$n")
        mark=""
        [[ "$n" == "$def" ]] && mark="  ${CYAN}(по умолчанию)${NC}"
        echo -e "    ${idx}) ${n}  [${status_text}]${mark}"
    done
    echo ""
    local prompt_def=""
    [[ -n "$def" ]] && prompt_def=" [Enter — ${def}]"
    read -rp "  Номер${prompt_def} (или 0 для отмены): " num
    if [[ "$num" == "0" ]]; then
        return 1
    fi
    if [[ -z "$num" && -n "$def" ]]; then
        SELECTED_INSTANCE="$def"
        return 0
    fi
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#INSTANCES[@]} )); then
        SELECTED_INSTANCE="${INSTANCES[$((num - 1))]}"
        return 0
    fi
    log_error "Неверный номер"
    return 1
}

# Утилита: выбрать инстанс и сразу загрузить его в INST_*.
require_instance() {
    select_instance_interactive || return 1
    instance_load "$SELECTED_INSTANCE" || return 1
    return 0
}

# Выбор инстанса для CLI-режима. Учитывает CLI_INSTANCE (от `-i name`).
# Если CLI_INSTANCE задан — используем. Иначе берём дефолт.
# Если дефолта нет и инстансов >1 — ошибка с подсказкой.
cli_select_instance() {
    SELECTED_INSTANCE=""
    if [[ -n "${CLI_INSTANCE:-}" ]]; then
        if ! instance_exists "$CLI_INSTANCE"; then
            log_error "Инстанс не найден: ${CLI_INSTANCE}"
            return 1
        fi
        SELECTED_INSTANCE="$CLI_INSTANCE"
        return 0
    fi
    instance_list
    if [[ ${#INSTANCES[@]} -eq 0 ]]; then
        log_error "Ни одного инстанса не настроено. Запустите интерактивное меню для создания."
        return 1
    fi
    local def
    def=$(instance_default)
    if [[ -n "$def" ]]; then
        SELECTED_INSTANCE="$def"
        return 0
    fi
    log_error "Несколько инстансов и не задан дефолтный. Используйте: $0 -i <имя> <команда>"
    echo "  Доступные инстансы: ${INSTANCES[*]}" >&2
    return 1
}

# ============================================================================
#  ОПРЕДЕЛЕНИЕ ПЛАТФОРМЫ И ВЕРСИЙ (глобально, не зависит от инстансов)
# ============================================================================

# Имя версии 1С: 8.3.NN.NNNN (точные четыре числа через точки).
# Защита от path traversal в путях /opt/1cv8/x86_64/<ver>/ и packages/<ver>/.
version_name_valid() {
    local ver="$1"
    [[ "$ver" =~ ^8\.3\.[0-9]+\.[0-9]+$ ]]
}

# Возвращает массив установленных версий (у которых есть crserver)
get_installed_versions() {
    INSTALLED_VERSIONS=()
    if [[ -d /opt/1cv8/x86_64 ]]; then
        local ver
        for dir in /opt/1cv8/x86_64/*/; do
            if [[ -f "${dir}crserver" ]]; then
                ver=$(basename "$dir")
                version_name_valid "$ver" || continue
                INSTALLED_VERSIONS+=("$ver")
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
            version_name_valid "$ver" || continue
            crs_match=$(find "$dir" -maxdepth 1 -name '1c-enterprise-*-crs_*.deb' ! -name '*-nls*' 2>/dev/null | head -1)
            [[ -n "$crs_match" ]] && AVAILABLE_VERSIONS+=("$ver")
        done
    fi
}

validate_version_packages() {
    local ver="$1"
    if ! version_name_valid "$ver"; then
        return 1
    fi
    local dir="${PACKAGES_DIR}/${ver}"
    [[ -d "$dir" ]] || return 1
    local kind found
    for kind in common server ws crs; do
        found=$(find "$dir" -maxdepth 1 -name "1c-enterprise-*-${kind}_*.deb" ! -name '*-nls*' 2>/dev/null | head -1)
        [[ -n "$found" ]] || return 1
    done
    return 0
}

detect_1c_user() {
    SVC_USER="usr1cv8"
    SVC_GROUP=""
    if id "$SVC_USER" &>/dev/null; then
        SVC_GROUP=$(id -gn "$SVC_USER")
    fi
}

get_primary_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "${ip:-127.0.0.1}"
}

# ============================================================================
#  SYSTEMD TEMPLATE
# ============================================================================

# Создаёт /etc/systemd/system/crserver@.service, если его ещё нет.
# Если уже есть — НИЧЕГО не делает (политика: не перезаписываем без явной команды).
generate_systemd_template() {
    if [[ -f "$SERVICE_TEMPLATE_FILE" ]]; then
        return 0
    fi
    detect_1c_user
    local svc_user="${SVC_USER:-usr1cv8}"
    local svc_group="${SVC_GROUP:-grp1cv8}"

    # Замечание про ProtectSystem=full (а не strict): systemd не раскрывает
    # ${VAR} в директиве ReadWritePaths, и пути инстансов разные. Поэтому
    # используем менее жёсткий full (запись в /var/* разрешена), а наши
    # каталоги все под /var/. ExecStart обернут в /bin/sh -c, чтобы systemd
    # не пытался запустить /opt/.../${VERSION}/crserver буквально.
    cat > "$SERVICE_TEMPLATE_FILE" << EOF
[Unit]
Description=1C:Enterprise Configuration Repository Server (instance %i)
Documentation=https://its.1c.ru
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/1c-crserver/instances/%i.conf
User=${svc_user}
Group=${svc_group}

ExecStartPre=/bin/sh -c 'mkdir -p "\${REPO_DIR}" "\${LOG_DIR}"; chown -R ${svc_user}:${svc_group} "\${REPO_DIR}" "\${LOG_DIR}"'
ExecStart=/bin/sh -c '/opt/1cv8/x86_64/\${VERSION}/crserver -d \${REPO_DIR} -port \${REPO_PORT}'

Restart=on-failure
RestartSec=10
TimeoutStopSec=30

StandardOutput=journal
StandardError=journal
SyslogIdentifier=crserver-%i

NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_TEMPLATE_FILE"
    systemctl daemon-reload || log_warn "systemctl daemon-reload завершился с ошибкой"
    return 0
}

# Принудительно регенерирует template (используется при миграции / ремонте).
regenerate_systemd_template() {
    rm -f "$SERVICE_TEMPLATE_FILE"
    generate_systemd_template
}

# ============================================================================
#  ОПРЕДЕЛЕНИЕ ЛЕГАСИ-УСТАНОВКИ И МИГРАЦИЯ
# ============================================================================

# Заполняет LEGACY_VERSION/LEGACY_PORT/LEGACY_REPO_DIR/LEGACY_LOG_DIR/LEGACY_BIN.
# Возвращает 0 — старая установка обнаружена, 1 — нет.
get_legacy_install() {
    LEGACY_VERSION=""
    LEGACY_PORT=""
    LEGACY_REPO_DIR=""
    LEGACY_LOG_DIR=""
    LEGACY_BIN=""

    if [[ ! -f "$LEGACY_SERVICE_FILE" ]]; then
        return 1
    fi

    local exec_line
    exec_line=$(grep "^ExecStart=" "$LEGACY_SERVICE_FILE" 2>/dev/null || true)
    if [[ -n "$exec_line" ]]; then
        LEGACY_BIN=$(echo "$exec_line" | sed 's/^ExecStart=//' | awk '{print $1}')
        LEGACY_VERSION=$(echo "$LEGACY_BIN" | grep -oP '8\.3\.\d+\.\d+' || true)
        # -port из строки ExecStart
        LEGACY_PORT=$(echo "$exec_line" | grep -oP -- '-port[ =]+\K[0-9]+' | head -1 || true)
        LEGACY_REPO_DIR=$(echo "$exec_line" | grep -oP -- '-d[ =]+\K[^ ]+' | head -1 || true)
    fi

    if [[ -f "$LEGACY_CONFIG_FILE" ]]; then
        local line key val
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line//[[:space:]]/}" ]] && continue
            if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=\"?([^\"]*)\"?[[:space:]]*$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                case "$key" in
                    REPO_DIR)  [[ -z "$LEGACY_REPO_DIR" ]] && LEGACY_REPO_DIR="$val" ;;
                    REPO_PORT) [[ -z "$LEGACY_PORT" ]]     && LEGACY_PORT="$val" ;;
                    LOG_DIR)   LEGACY_LOG_DIR="$val" ;;
                esac
            fi
        done < "$LEGACY_CONFIG_FILE"
    fi

    LEGACY_REPO_DIR="${LEGACY_REPO_DIR:-/var/1c/repo}"
    LEGACY_PORT="${LEGACY_PORT:-1542}"
    LEGACY_LOG_DIR="${LEGACY_LOG_DIR:-/var/log/1c/crserver}"
    # Юнит без распознаваемой версии — повреждённая установка, не "обнаружена".
    if [[ -z "$LEGACY_VERSION" ]]; then
        return 1
    fi
    return 0
}

# Перенос каталога с откатом при ошибке.
# $1 — src, $2 — dst. Использует mv в пределах одной FS, иначе rsync/cp -a.
move_dir_safe() {
    local src="$1" dst="$2"
    if [[ ! -d "$src" ]]; then
        return 0
    fi
    if [[ -e "$dst" ]]; then
        log_error "Целевой путь уже существует: $dst"
        return 1
    fi
    mkdir -p "$(dirname "$dst")"

    # Если src и dst на разных ФС — будет копирование. Проверим, что
    # на целевой ФС хватит места. Сравниваем размер src в KiB и
    # доступное место на dst в KiB.
    local src_dev dst_dev
    src_dev=$(stat -c '%d' "$src" 2>/dev/null || echo 0)
    dst_dev=$(stat -c '%d' "$(dirname "$dst")" 2>/dev/null || echo 0)
    if [[ "$src_dev" != "$dst_dev" ]]; then
        local src_kb avail_kb
        src_kb=$(du -sk "$src" 2>/dev/null | awk '{print $1+0}')
        avail_kb=$(df --output=avail -k "$(dirname "$dst")" 2>/dev/null | awk 'NR==2 {print $1+0}')
        if [[ -n "$src_kb" && -n "$avail_kb" && "$avail_kb" -lt "$src_kb" ]]; then
            log_error "Недостаточно места на целевой ФС: нужно ${src_kb}K, доступно ${avail_kb}K"
            return 1
        fi
    fi
    # Пробуем mv (быстро если та же FS)
    if mv "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    # Иначе копируем и удаляем
    log_step "Копирование ${src} → ${dst} (другая ФС)..."
    if command -v rsync >/dev/null 2>&1; then
        if ! rsync -aHAX "${src}/" "${dst}/"; then
            log_error "rsync не удался"
            rm -rf "$dst"
            return 1
        fi
    else
        if ! cp -a "$src" "$dst"; then
            log_error "cp -a не удался"
            rm -rf "$dst"
            return 1
        fi
    fi
    rm -rf "$src" || log_warn "Не удалось удалить исходный каталог: $src"
    return 0
}

migrate_legacy() {
    if ! get_legacy_install; then
        log_warn "Старая установка не обнаружена (нет ${LEGACY_SERVICE_FILE})"
        return 0
    fi

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Миграция v1.x → v2.0 (мульти-инстанс)${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Обнаружена старая установка:"
    echo "    Юнит:        ${LEGACY_SERVICE_FILE}"
    echo "    Версия:      ${LEGACY_VERSION:-?}"
    echo "    Бинарник:    ${LEGACY_BIN:-?}"
    echo "    Порт:        ${LEGACY_PORT}"
    echo "    Хранилища:   ${LEGACY_REPO_DIR}"
    echo "    Логи:        ${LEGACY_LOG_DIR}"
    echo ""
    echo "  Будет выполнено:"
    echo "    1. Остановка и удаление crserver.service"
    echo "    2. Перенос ${LEGACY_REPO_DIR} → /var/1c/repo-<имя>"
    echo "    3. Перенос ${LEGACY_LOG_DIR} → /var/log/1c/<имя>"
    echo "    4. Создание /etc/1c-crserver/instances/<имя>.conf"
    echo "    5. Установка crserver@<имя> как инстанса по умолчанию"
    echo "    6. Сохранение старого crserver.conf как .legacy для подстраховки"
    echo ""
    read -rp "  Имя инстанса [default]: " new_name
    new_name="${new_name:-default}"
    if ! instance_name_valid "$new_name"; then
        log_error "Недопустимое имя: '${new_name}' (нужно ^[a-z][a-z0-9-]{0,31}$)"
        return 1
    fi
    if instance_exists "$new_name"; then
        log_error "Инстанс с таким именем уже существует: ${new_name}"
        return 1
    fi

    if [[ -z "$LEGACY_VERSION" ]]; then
        log_error "Не удалось определить версию из старого юнита. Прерываю."
        return 1
    fi

    echo ""
    read -rp "  Подтвердить миграцию? (Y/n): " ans
    if [[ "$ans" =~ ^[Nn]$ ]]; then
        log_warn "Миграция отменена"
        return 0
    fi

    log_step "Остановка старой службы..."
    systemctl stop crserver.service 2>/dev/null || true
    systemctl disable crserver.service 2>/dev/null || true

    local new_repo_dir="${REPO_BASE}/repo-${new_name}"
    local new_log_dir="${LOG_BASE}/${new_name}"

    # Если репо-директория уже совпадает с целевой — пропускаем перенос.
    if [[ "$LEGACY_REPO_DIR" != "$new_repo_dir" ]]; then
        log_step "Перенос каталога хранилищ..."
        if ! move_dir_safe "$LEGACY_REPO_DIR" "$new_repo_dir"; then
            log_error "Перенос хранилищ не удался — миграция прервана"
            return 1
        fi
    else
        log_info "Каталог хранилищ уже на месте: ${new_repo_dir}"
        mkdir -p "$new_repo_dir"
    fi

    if [[ -d "$LEGACY_LOG_DIR" && "$LEGACY_LOG_DIR" != "$new_log_dir" ]]; then
        log_step "Перенос каталога логов..."
        move_dir_safe "$LEGACY_LOG_DIR" "$new_log_dir" || \
            log_warn "Не удалось перенести логи (продолжаем)"
    fi
    mkdir -p "$new_log_dir"

    detect_1c_user
    if [[ -n "${SVC_USER:-}" && -n "${SVC_GROUP:-}" ]]; then
        chown -R "${SVC_USER}:${SVC_GROUP}" "$new_repo_dir" "$new_log_dir" 2>/dev/null || true
    fi

    log_step "Создание конфига инстанса..."
    INST_VERSION="$LEGACY_VERSION"
    INST_PORT="$LEGACY_PORT"
    INST_REPO_DIR="$new_repo_dir"
    INST_LOG_DIR="$new_log_dir"
    if ! instance_save "$new_name"; then
        log_error "Не удалось сохранить конфиг инстанса"
        return 1
    fi

    log_step "Удаление старого юнита..."
    rm -f "$LEGACY_SERVICE_FILE"

    log_step "Архивация старого crserver.conf..."
    if [[ -f "$LEGACY_CONFIG_FILE" ]]; then
        mv -f "$LEGACY_CONFIG_FILE" "${LEGACY_CONFIG_FILE}.legacy" || \
            log_warn "Не удалось переименовать ${LEGACY_CONFIG_FILE}"
    fi

    log_step "Генерация systemd-template..."
    generate_systemd_template
    systemctl daemon-reload

    log_step "Запуск crserver@${new_name}..."
    if systemctl enable "crserver@${new_name}.service" >/dev/null 2>&1; then
        log_info "enabled: crserver@${new_name}"
    else
        log_warn "systemctl enable вернул ошибку"
    fi
    if systemctl start "crserver@${new_name}.service"; then
        log_info "Инстанс ${new_name} запущен"
    else
        log_error "Не удалось запустить crserver@${new_name}"
        echo "  Лог: journalctl -u crserver@${new_name} -n 50"
    fi

    instance_set_default "$new_name"
    log_info "Установлен по умолчанию: ${new_name}"

    # Файрвол: убираем INPUT-правило старого порта, добавляем для нового
    setup_firewall_chain
    add_input_for_port "$INST_PORT"

    echo ""
    log_info "Миграция завершена"
    echo ""
    return 0
}

# ============================================================================
#  УПРАВЛЕНИЕ ПЛАТФОРМЕННЫМИ ВЕРСИЯМИ — МЕНЮ
# ============================================================================

do_version_menu() {
    while true; do
        get_installed_versions
        get_available_versions

        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Управление версиями платформы 1С"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""

        echo -n "  Установленные:    "
        if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
            local first=1 v
            for v in "${INSTALLED_VERSIONS[@]}"; do
                [[ $first -eq 0 ]] && echo -n ", "
                echo -n "$v"
                first=0
            done
            echo ""
        else
            echo "(нет)"
        fi

        echo -n "  Пакеты (packages/): "
        if [[ ${#AVAILABLE_VERSIONS[@]} -gt 0 ]]; then
            local first=1 v installed iv
            for v in "${AVAILABLE_VERSIONS[@]}"; do
                [[ $first -eq 0 ]] && echo -n ", "
                installed=0
                for iv in "${INSTALLED_VERSIONS[@]+"${INSTALLED_VERSIONS[@]}"}"; do
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
        echo "  Версии устанавливаются глобально и используются инстансами."
        echo "  Чтобы переключить инстанс на другую версию, отредактируйте"
        echo "  его в меню «Инстансы» → «Изменить»."
        echo ""
        echo "  1) Установить версию"
        echo "  2) Удалить версию"
        echo "  3) Импорт пакетов в packages/"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1) do_install_version ;;
            2) do_uninstall_version ;;
            3) do_import_packages ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

do_install_version() {
    get_available_versions
    get_installed_versions

    local to_install=() v iv already
    for v in "${AVAILABLE_VERSIONS[@]+"${AVAILABLE_VERSIONS[@]}"}"; do
        already=0
        for iv in "${INSTALLED_VERSIONS[@]+"${INSTALLED_VERSIONS[@]}"}"; do
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

    # Ставим все 4 пакета одной командой apt-get install — apt сам разрулит
    # порядок установки и подтянет недостающие зависимости (libwebkit2gtk и
    # пр.). Это надёжнее, чем серия dpkg -i + последующий install -f, при
    # котором первая ошибка зависимостей рушит остальные пакеты.
    local dpkg_failed=0
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            "$COMMON_PKG" "$SERVER_PKG" "$WS_PKG" "$CRS_PKG" \
            >/tmp/crserver-dpkg.log 2>&1; then
        log_warn "apt-get install для пакетов 1С завершился с ошибкой:"
        tail -10 /tmp/crserver-dpkg.log | sed 's/^/    /'
        # Запасной путь: попробуем dpkg+install -f (на случай старого apt без поддержки .deb пути).
        local pkg
        for pkg in "$COMMON_PKG" "$SERVER_PKG" "$WS_PKG" "$CRS_PKG"; do
            dpkg -i "$pkg" >>/tmp/crserver-dpkg.log 2>&1 || dpkg_failed=1
        done
        if ! apt-get install -f -y -qq >>/tmp/crserver-dpkg.log 2>&1; then
            dpkg_failed=1
        fi
    fi
    rm -f /tmp/crserver-dpkg.log

    if [[ $dpkg_failed -eq 1 ]]; then
        log_warn "Установка пакетов прошла с ошибками, проверьте вывод выше"
    fi

    local crserver_bin="/opt/1cv8/x86_64/${ver}/crserver"
    if [[ ! -f "$crserver_bin" ]]; then
        log_error "crserver не найден: $crserver_bin"
        return 1
    fi

    log_info "Версия ${ver} установлена"

    if systemctl list-unit-files 2>/dev/null | grep -q "srv1cv8"; then
        systemctl stop srv1cv8 2>/dev/null || true
        systemctl disable srv1cv8 2>/dev/null || true
    fi
    return 0
}

do_uninstall_version() {
    get_installed_versions

    if [[ ${#INSTALLED_VERSIONS[@]} -eq 0 ]]; then
        log_warn "Нет установленных версий"
        read -rp "  Нажмите Enter..." _
        return
    fi

    # Собираем версии, используемые активными инстансами — их удалять опасно
    instance_list
    local used_by=() name conf_ver
    for name in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
        conf_ver=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "${INSTANCES_DIR}/${name}.conf" 2>/dev/null || true)
        [[ -n "$conf_ver" ]] && used_by+=("${conf_ver}:${name}")
    done

    echo ""
    echo "  Установленные версии:"
    local idx=0 v u using
    for v in "${INSTALLED_VERSIONS[@]}"; do
        idx=$((idx + 1))
        using=""
        for u in "${used_by[@]+"${used_by[@]}"}"; do
            if [[ "$u" == "${v}:"* ]]; then
                using+=" ${u#*:}"
            fi
        done
        if [[ -n "$using" ]]; then
            echo -e "    ${idx}) ${v}  ${YELLOW}← используется инстансами:${using}${NC}"
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
        local in_use=0 u
        for u in "${used_by[@]+"${used_by[@]}"}"; do
            [[ "$u" == "${selected}:"* ]] && in_use=1
        done
        if [[ $in_use -eq 1 ]]; then
            echo ""
            log_warn "Версия ${selected} используется инстансами. Удаление сделает их фантомами."
            read -rp "  Продолжить? (y/N): " answer
            if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                return
            fi
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

    dpkg --purge "1c-enterprise-${ver}-crs"    2>/dev/null || true
    dpkg --purge "1c-enterprise-${ver}-ws"     2>/dev/null || true
    dpkg --purge "1c-enterprise-${ver}-server" 2>/dev/null || true
    dpkg --purge "1c-enterprise-${ver}-common" 2>/dev/null || true
    apt-get autoremove -y -qq > /dev/null 2>&1 || true

    if [[ -f "/opt/1cv8/x86_64/${ver}/crserver" ]]; then
        log_warn "Файлы версии ${ver} остались (возможно, заняты другими пакетами)"
    else
        log_info "Версия ${ver} удалена"
    fi
}

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

    local found_versions=()
    local crs_file ver fv dup
    while IFS= read -r crs_file; do
        ver=$(basename "$crs_file" | grep -oP '8\.3\.\d+\.\d+' || true)
        if [[ -n "$ver" ]]; then
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
#  ИНСТАНСЫ — МЕНЮ И ОПЕРАЦИИ
# ============================================================================

do_instance_menu() {
    while true; do
        instance_list
        local def
        def=$(instance_default)

        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Инстансы (crserver@<имя>)"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""

        if [[ ${#INSTANCES[@]} -eq 0 ]]; then
            echo "  (инстансов нет)"
        else
            echo "  Существующие:"
            echo "  ─────────────────────────────────────────────"
            local n status_text status_color mark ver port
            for n in "${INSTANCES[@]}"; do
                status_text=$(instance_status "$n")
                case "$status_text" in
                    running) status_color="${GREEN}" ;;
                    stopped) status_color="${YELLOW}" ;;
                    failed)  status_color="${RED}" ;;
                    phantom) status_color="${RED}" ;;
                    *)       status_color="${NC}" ;;
                esac
                mark=""
                [[ "$n" == "$def" ]] && mark=" ${CYAN}(default)${NC}"
                ver=$(awk -F'"' '/^VERSION=/   {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
                port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
                echo -e "    ${n}  v${ver:-?}  port=${port:-?}  [${status_color}${status_text}${NC}]${mark}"
            done
        fi

        local legacy_present=0
        if [[ -f "$LEGACY_SERVICE_FILE" ]]; then
            legacy_present=1
        fi

        echo ""
        echo "  1) Создать инстанс"
        echo "  2) Удалить инстанс"
        echo "  3) Изменить инстанс (версия/порт/каталоги)"
        echo "  4) Назначить инстанс по умолчанию"
        echo "  5) Подробная информация об инстансе"
        echo "  6) Запустить/Остановить/Перезапустить"
        if [[ $legacy_present -eq 1 ]]; then
            echo -e "  7) ${YELLOW}Миграция со старой установки (v1.x → v2)${NC}"
        fi
        echo "  8) Регенерировать systemd-template"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1) do_instance_create ;;
            2) do_instance_delete ;;
            3) do_instance_edit ;;
            4) do_instance_set_default ;;
            5) do_instance_info ;;
            6) do_instance_service ;;
            7)
                if [[ $legacy_present -eq 1 ]]; then
                    migrate_legacy
                    read -rp "  Нажмите Enter..." _
                else
                    log_warn "Неверный выбор"
                fi
                ;;
            8)
                regenerate_systemd_template
                log_info "Template /etc/systemd/system/crserver@.service создан/перезаписан"
                read -rp "  Нажмите Enter..." _
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

do_instance_create() {
    echo ""
    echo "  Создание нового инстанса"
    echo "  ─────────────────────────────────────────────"
    read -rp "  Имя (a-z, цифры, дефисы; до 32 символов): " name
    if ! instance_name_valid "$name"; then
        log_error "Недопустимое имя"
        return
    fi
    if instance_exists "$name"; then
        log_error "Инстанс уже существует: ${name}"
        return
    fi

    get_installed_versions
    if [[ ${#INSTALLED_VERSIONS[@]} -eq 0 ]]; then
        log_error "Нет установленных версий 1С. Установите версию через меню «Управление версиями»."
        return
    fi

    local ver=""
    if [[ ${#INSTALLED_VERSIONS[@]} -eq 1 ]]; then
        ver="${INSTALLED_VERSIONS[0]}"
        echo "  Версия:    ${ver}  (единственная установленная)"
    else
        echo ""
        echo "  Установленные версии:"
        local idx=0 v
        for v in "${INSTALLED_VERSIONS[@]}"; do
            idx=$((idx + 1))
            echo "    ${idx}) ${v}"
        done
        read -rp "  Номер: " num
        if ! [[ "$num" =~ ^[0-9]+$ ]] || (( num < 1 || num > ${#INSTALLED_VERSIONS[@]} )); then
            log_error "Неверный номер"
            return
        fi
        ver="${INSTALLED_VERSIONS[$((num - 1))]}"
    fi

    local default_port="${DEFAULT_REPO_PORT}"
    # Если порт уже занят другим инстансом — предложим следующий свободный
    instance_list
    local n existing_port
    for n in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
        existing_port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
        if [[ "$existing_port" == "$default_port" ]]; then
            default_port=$((default_port + 1))
        fi
    done

    read -rp "  Порт [${default_port}]: " port
    port="${port:-$default_port}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "Некорректный порт"
        return
    fi
    # Проверка, что порт не занят другим инстансом
    for n in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
        existing_port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
        if [[ "$existing_port" == "$port" ]]; then
            log_error "Порт ${port} уже используется инстансом ${n}"
            return
        fi
    done
    # Дополнительно: порт может быть занят сторонним процессом (другой
    # сервис, забытый процесс crserver, тестовый сокет и т.п.).
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnH 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END {exit !found}'; then
            log_warn "Порт ${port} уже слушается каким-то процессом:"
            ss -tlnpH 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$"' | sed 's/^/    /'
            read -rp "  Всё равно создать инстанс? (y/N): " ans
            if [[ ! "$ans" =~ ^[Yy]$ ]]; then
                log_warn "Отменено"
                return
            fi
        fi
    fi

    local default_repo="${REPO_BASE}/repo-${name}"
    local default_log="${LOG_BASE}/${name}"
    read -rp "  Каталог хранилищ [${default_repo}]: " repo_dir
    repo_dir="${repo_dir:-$default_repo}"
    read -rp "  Каталог логов     [${default_log}]: " log_dir
    log_dir="${log_dir:-$default_log}"

    INST_VERSION="$ver"
    INST_PORT="$port"
    INST_REPO_DIR="$repo_dir"
    INST_LOG_DIR="$log_dir"

    if ! instance_save "$name"; then
        return 1
    fi

    detect_1c_user
    mkdir -p "$repo_dir" "$log_dir" "$BACKUP_DIR"
    if [[ -n "${SVC_USER:-}" && -n "${SVC_GROUP:-}" ]]; then
        chown -R "${SVC_USER}:${SVC_GROUP}" "$repo_dir" "$log_dir" 2>/dev/null || true
    fi

    generate_systemd_template
    systemctl daemon-reload

    if systemctl enable "crserver@${name}.service" >/dev/null 2>&1; then
        log_info "enabled: crserver@${name}"
    else
        log_warn "systemctl enable вернул ошибку"
    fi

    add_input_for_port "$port"

    # Если это первый инстанс — назначим дефолтным
    instance_list
    if [[ ${#INSTANCES[@]} -eq 1 ]]; then
        instance_set_default "$name"
        log_info "Установлен по умолчанию: ${name}"
    fi

    echo ""
    log_info "Инстанс ${name} создан"
    echo "  Запустить: systemctl start crserver@${name}  (или через меню → 6)"
    read -rp "  Нажмите Enter..." _
}

do_instance_delete() {
    if ! select_instance_interactive; then
        return
    fi
    local name="$SELECTED_INSTANCE"
    instance_load "$name" || return 1

    echo ""
    echo "  Удаление инстанса '${name}'"
    echo "  ─────────────────────────────────────────────"
    echo "    Версия:    ${INST_VERSION}"
    echo "    Порт:      ${INST_PORT}"
    echo "    Хранилища: ${INST_REPO_DIR}"
    echo "    Логи:      ${INST_LOG_DIR}"
    echo ""
    log_warn "Будут удалены: конфиг инстанса, systemd-юнит (disabled), правило файрвола."
    log_warn "Каталог хранилищ ПО УМОЛЧАНИЮ НЕ удаляется."
    echo ""
    read -rp "  Удалить также каталог хранилищ? (y/N): " purge_ans
    local purge=0
    [[ "$purge_ans" =~ ^[Yy]$ ]] && purge=1

    echo ""
    read -rp "  Введите имя инстанса '${name}' для подтверждения: " confirm
    if [[ "$confirm" != "$name" ]]; then
        log_warn "Отменено (имя не совпало)"
        return
    fi

    log_step "Остановка..."
    systemctl stop "crserver@${name}.service" 2>/dev/null || true
    systemctl disable "crserver@${name}.service" 2>/dev/null || true

    # ВАЖНО: чистим файрвол ДО удаления конфига — cleanup_instance_chain
    # читает REPO_PORT из <name>.conf, чтобы найти INPUT-ссылки на per-instance цепочку.
    cleanup_instance_chain "$name"
    remove_input_for_port "$INST_PORT"

    rm -f "${INSTANCES_DIR}/${name}.conf"
    log_info "Конфиг удалён: ${INSTANCES_DIR}/${name}.conf"

    if [[ $purge -eq 1 ]]; then
        if [[ -d "$INST_REPO_DIR" ]]; then
            log_step "Удаление каталога хранилищ ${INST_REPO_DIR}..."
            rm -rf "$INST_REPO_DIR" || log_warn "rm -rf завершился с ошибкой"
        fi
    fi

    # Если это был дефолтный — снимаем указатель
    if [[ -f "$DEFAULT_INSTANCE_FILE" ]]; then
        local cur
        cur=$(head -1 "$DEFAULT_INSTANCE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$cur" == "$name" ]]; then
            rm -f "$DEFAULT_INSTANCE_FILE"
            log_info "Сняли указатель default-instance"
        fi
    fi

    systemctl daemon-reload
    log_info "Инстанс ${name} удалён"
    read -rp "  Нажмите Enter..." _
}

do_instance_edit() {
    if ! select_instance_interactive; then
        return
    fi
    local name="$SELECTED_INSTANCE"
    instance_load "$name" || return 1

    echo ""
    echo "  Редактирование '${name}' (Enter — оставить как есть)"
    echo "  ─────────────────────────────────────────────"

    get_installed_versions
    echo "  Установленные версии: ${INSTALLED_VERSIONS[*]:-(нет)}"
    read -rp "  VERSION   [${INST_VERSION}]: " new_ver
    new_ver="${new_ver:-$INST_VERSION}"

    # Понижение версии (8.3.30 -> 8.3.25) после того, как формат хранилища
    # уже был обновлён конфигуратором, как правило необратимо: данные
    # перестанут читаться. Предупреждаем явно.
    if [[ "$new_ver" != "$INST_VERSION" ]]; then
        local cur_ver_cmp new_ver_cmp
        cur_ver_cmp=$(awk -F. '{printf "%03d%03d%03d%03d", $1,$2,$3,$4}' <<< "$INST_VERSION")
        new_ver_cmp=$(awk -F. '{printf "%03d%03d%03d%03d", $1,$2,$3,$4}' <<< "$new_ver")
        if [[ -n "$new_ver_cmp" && -n "$cur_ver_cmp" && "$new_ver_cmp" < "$cur_ver_cmp" ]]; then
            echo ""
            log_warn "Понижение версии: ${INST_VERSION} → ${new_ver}"
            log_warn "Если формат хранилища уже обновлялся конфигуратором, понижение"
            log_warn "может сделать данные нечитаемыми (это необратимо)."
            read -rp "  Подтверждаете? (y/N): " ans
            if [[ ! "$ans" =~ ^[Yy]$ ]]; then
                log_warn "Отменено"
                return
            fi
        fi
    fi

    read -rp "  PORT      [${INST_PORT}]: " new_port
    new_port="${new_port:-$INST_PORT}"
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        log_error "Некорректный порт"
        return
    fi
    # Проверка коллизий портов с другими инстансами
    if [[ "$new_port" != "$INST_PORT" ]]; then
        instance_list
        local n existing_port
        for n in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
            [[ "$n" == "$name" ]] && continue
            existing_port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
            if [[ "$existing_port" == "$new_port" ]]; then
                log_error "Порт ${new_port} уже используется инстансом ${n}"
                return
            fi
        done
    fi

    read -rp "  REPO_DIR  [${INST_REPO_DIR}]: " new_repo
    new_repo="${new_repo:-$INST_REPO_DIR}"
    read -rp "  LOG_DIR   [${INST_LOG_DIR}]: " new_log
    new_log="${new_log:-$INST_LOG_DIR}"

    local was_active=0
    if systemctl is-active --quiet "crserver@${name}.service" 2>/dev/null; then
        was_active=1
    fi

    if [[ $was_active -eq 1 ]]; then
        log_step "Останавливаю инстанс на время изменения..."
        systemctl stop "crserver@${name}.service" 2>/dev/null || true
    fi

    # Если меняется REPO_DIR — переносим (или хотя бы создаём новый)
    if [[ "$new_repo" != "$INST_REPO_DIR" ]]; then
        if [[ -d "$INST_REPO_DIR" && ! -e "$new_repo" ]]; then
            log_step "Перенос каталога хранилищ..."
            move_dir_safe "$INST_REPO_DIR" "$new_repo" || log_warn "Перенос не удался — создаю пустой"
        fi
        mkdir -p "$new_repo"
    fi
    if [[ "$new_log" != "$INST_LOG_DIR" ]]; then
        if [[ -d "$INST_LOG_DIR" && ! -e "$new_log" ]]; then
            move_dir_safe "$INST_LOG_DIR" "$new_log" || log_warn "Перенос логов не удался"
        fi
        mkdir -p "$new_log"
    fi

    # Файрвол: если порт изменился — обновим INPUT
    if [[ "$new_port" != "$INST_PORT" ]]; then
        remove_input_for_port "$INST_PORT"
        add_input_for_port "$new_port"
    fi

    INST_VERSION="$new_ver"
    INST_PORT="$new_port"
    INST_REPO_DIR="$new_repo"
    INST_LOG_DIR="$new_log"

    if ! instance_save "$name"; then
        log_error "Не удалось сохранить конфиг"
        return 1
    fi

    detect_1c_user
    if [[ -n "${SVC_USER:-}" && -n "${SVC_GROUP:-}" ]]; then
        chown -R "${SVC_USER}:${SVC_GROUP}" "$INST_REPO_DIR" "$INST_LOG_DIR" 2>/dev/null || true
    fi

    systemctl daemon-reload
    log_info "Инстанс ${name} обновлён"

    if [[ $was_active -eq 1 ]]; then
        log_step "Запуск..."
        if systemctl start "crserver@${name}.service"; then
            log_info "Запущен"
        else
            log_error "Не удалось запустить — journalctl -u crserver@${name}"
        fi
    fi
    read -rp "  Нажмите Enter..." _
}

do_instance_set_default() {
    if ! select_instance_interactive; then
        return
    fi
    if instance_set_default "$SELECTED_INSTANCE"; then
        log_info "По умолчанию: ${SELECTED_INSTANCE}"
    fi
    read -rp "  Нажмите Enter..." _
}

do_instance_info() {
    if ! select_instance_interactive; then
        return
    fi
    local name="$SELECTED_INSTANCE"
    instance_load "$name" || return 1
    local status_text bin ip_addr
    status_text=$(instance_status "$name")
    bin="/opt/1cv8/x86_64/${INST_VERSION}/crserver"
    ip_addr=$(get_primary_ip)

    echo ""
    echo "  Инстанс '${name}'"
    echo "  ─────────────────────────────────────────────"
    echo "    Статус:        ${status_text}"
    echo "    Юнит:          crserver@${name}.service"
    echo "    Версия:        ${INST_VERSION}"
    echo "    Бинарник:      ${bin}$([ -f "$bin" ] || echo "  (НЕ СУЩЕСТВУЕТ)")"
    echo "    Порт:          ${INST_PORT}"
    echo "    Каталог:       ${INST_REPO_DIR}"
    echo "    Логи:          ${INST_LOG_DIR}"
    echo "    Адрес:         tcp://${ip_addr}:${INST_PORT}/<имя_хранилища>"
    if ss -tlnH 2>/dev/null | awk -v p=":${INST_PORT}" '$4 ~ p"$" {found=1} END {exit !found}'; then
        echo "    Порт слушается: да"
    else
        echo "    Порт слушается: нет"
    fi
    echo ""
    read -rp "  Нажмите Enter..." _
}

do_instance_service() {
    if ! select_instance_interactive; then
        return
    fi
    local name="$SELECTED_INSTANCE"
    while true; do
        local status_text status_color
        status_text=$(instance_status "$name")
        case "$status_text" in
            running) status_color="${GREEN}" ;;
            failed|phantom) status_color="${RED}" ;;
            *)       status_color="${YELLOW}" ;;
        esac

        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Управление инстансом '${name}'   Статус: ${status_color}${status_text}${NC}"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""
        echo "  1) Запустить"
        echo "  2) Остановить"
        echo "  3) Перезапустить"
        echo "  4) Подробный статус"
        echo "  5) Логи (последние 50)"
        echo "  6) Логи в реальном времени"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice
        local unit="crserver@${name}.service"
        case $choice in
            1)
                if systemctl start "$unit"; then log_info "Запущен"; else log_error "Ошибка"; fi
                sleep 1
                ;;
            2)
                if systemctl stop "$unit"; then log_info "Остановлен"; else log_error "Ошибка"; fi
                ;;
            3)
                if systemctl restart "$unit"; then log_info "Перезапущен"; else log_error "Ошибка"; fi
                sleep 1
                ;;
            4)
                echo ""
                systemctl status "$unit" --no-pager 2>/dev/null || log_warn "Юнит не найден"
                read -rp "  Нажмите Enter..." _
                ;;
            5)
                echo ""
                journalctl -u "$unit" -n 50 --no-pager 2>/dev/null || log_warn "Нет логов"
                read -rp "  Нажмите Enter..." _
                ;;
            6)
                echo ""
                echo "  (Ctrl+C для выхода)"
                journalctl -u "$unit" -f 2>/dev/null || true
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

# ============================================================================
#  ПОЛНАЯ УСТАНОВКА (ПЕРВЫЙ РАЗ)
# ============================================================================

do_full_install() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Первичная установка сервера хранилища 1С${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""

    # Если есть старая установка — предлагаем миграцию
    if [[ -f "$LEGACY_SERVICE_FILE" ]]; then
        log_warn "Обнаружена старая установка (crserver.service). Используйте миграцию"
        log_warn "из меню «Инстансы» → «Миграция со старой установки» вместо install."
        echo ""
        read -rp "  Открыть меню миграции сейчас? (Y/n): " ans
        if [[ ! "$ans" =~ ^[Nn]$ ]]; then
            migrate_legacy
        fi
        return
    fi

    get_available_versions
    if [[ ${#AVAILABLE_VERSIONS[@]} -eq 0 ]]; then
        log_warn "Нет доступных пакетов в ${PACKAGES_DIR}/"
        echo ""
        echo "  Шаг 1: создайте каталог:    mkdir -p ${PACKAGES_DIR}/8.3.25.1560"
        echo "  Шаг 2: скопируйте пакеты:   cp 1c-enterprise-*-{common,server,ws,crs}_*.deb ..."
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
        local idx=0 v
        for v in "${AVAILABLE_VERSIONS[@]}"; do
            idx=$((idx + 1))
            echo "    ${idx}) ${v}"
        done
        echo ""
        read -rp "  Выберите версию: " num
        if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#AVAILABLE_VERSIONS[@]} ]]; then
            target_ver="${AVAILABLE_VERSIONS[$((num - 1))]}"
        else
            log_error "Неверный номер"
            return
        fi
    fi

    if ! validate_version_packages "$target_ver"; then
        log_error "Неполный набор пакетов для ${target_ver}"
        read -rp "  Нажмите Enter..." _
        return
    fi

    echo ""
    read -rp "  Имя инстанса [default]: " inst_name
    inst_name="${inst_name:-default}"
    if ! instance_name_valid "$inst_name"; then
        log_error "Недопустимое имя инстанса"
        return
    fi
    if instance_exists "$inst_name"; then
        # Возможный сценарий: первая установка упала на systemctl start,
        # инстанс был сохранён, но не запущен. Предлагаем варианты вместо
        # тупика "уже существует".
        local existing_status
        existing_status=$(instance_status "$inst_name")
        echo ""
        log_warn "Инстанс '${inst_name}' уже существует (статус: ${existing_status})"
        echo "  Варианты:"
        echo "    1) Открыть меню инстанса (запуск/настройка/удаление)"
        echo "    2) Удалить и переустановить с нуля"
        echo "    0) Отмена"
        read -rp "  Выберите [0]: " resume_choice
        case "${resume_choice:-0}" in
            1)
                SELECTED_INSTANCE="$inst_name"
                do_instance_service
                return
                ;;
            2)
                log_step "Удаление существующего инстанса '${inst_name}'..."
                systemctl stop "crserver@${inst_name}.service" 2>/dev/null || true
                systemctl disable "crserver@${inst_name}.service" 2>/dev/null || true
                local _old_port
                _old_port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${inst_name}.conf" 2>/dev/null || true)
                cleanup_instance_chain "$inst_name"
                [[ -n "$_old_port" ]] && remove_input_for_port "$_old_port"
                rm -f "${INSTANCES_DIR}/${inst_name}.conf"
                log_info "Удалено. Продолжаю установку."
                ;;
            *)
                log_warn "Отменено"
                return
                ;;
        esac
    fi

    read -rp "  Порт [${DEFAULT_REPO_PORT}]: " inst_port
    inst_port="${inst_port:-$DEFAULT_REPO_PORT}"
    if ! [[ "$inst_port" =~ ^[0-9]+$ ]] || (( inst_port < 1 || inst_port > 65535 )); then
        log_error "Некорректный порт"
        return
    fi

    local inst_repo="${REPO_BASE}/repo-${inst_name}"
    local inst_log="${LOG_BASE}/${inst_name}"

    echo ""
    echo "  Будет установлено:"
    echo "    Версия:     ${target_ver}"
    echo "    Инстанс:    ${inst_name}"
    echo "    Порт:       ${inst_port}"
    echo "    Хранилища:  ${inst_repo}"
    echo "    Логи:       ${inst_log}"
    echo ""
    read -rp "  Начать установку? (Y/n): " answer
    if [[ "$answer" =~ ^[Nn]$ ]]; then
        return
    fi

    log_step "Установка системных зависимостей..."
    apt-get update -qq
    apt-get install -y -qq \
        wget tar fontconfig libfreetype6 libgsf-1-114 \
        libglib2.0-0 libodbc2 imagemagick locales curl \
        iptables-persistent rsync \
        > /dev/null 2>&1 || true
    log_info "Зависимости установлены"

    log_step "Настройка локали ru_RU.UTF-8..."
    sed -i 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    locale-gen > /dev/null 2>&1 || true
    log_info "Локаль настроена"

    install_version "$target_ver"

    log_step "Настройка пользователя..."
    detect_1c_user
    if [[ -z "${SVC_GROUP:-}" ]]; then
        groupadd -r grp1cv8 2>/dev/null || true
        useradd -r -s /bin/bash -m -d /home/usr1cv8 -g grp1cv8 usr1cv8 2>/dev/null || true
        SVC_GROUP="grp1cv8"
        log_info "Создан пользователь usr1cv8:grp1cv8"
    else
        log_info "Пользователь: ${SVC_USER}:${SVC_GROUP}"
    fi

    mkdir -p "$inst_repo" "$inst_log" "$BACKUP_DIR" "$INSTANCES_DIR"
    chown -R "${SVC_USER}:${SVC_GROUP}" "$inst_repo" "$inst_log"
    log_info "Каталоги созданы"

    INST_VERSION="$target_ver"
    INST_PORT="$inst_port"
    INST_REPO_DIR="$inst_repo"
    INST_LOG_DIR="$inst_log"
    if ! instance_save "$inst_name"; then
        log_error "Не удалось сохранить конфиг инстанса"
        return 1
    fi

    log_step "Создание systemd-template..."
    generate_systemd_template
    systemctl daemon-reload

    if systemctl enable "crserver@${inst_name}.service" >/dev/null 2>&1; then
        log_info "enabled: crserver@${inst_name}"
    else
        log_warn "systemctl enable вернул ошибку"
    fi

    instance_set_default "$inst_name"

    log_step "Настройка файрвола..."
    setup_firewall_chain
    add_input_for_port "$inst_port"
    log_info "Файрвол настроен"

    log_step "Запуск crserver@${inst_name}..."
    local start_rc=0
    systemctl start "crserver@${inst_name}.service" || start_rc=$?
    sleep 2

    if systemctl is-active --quiet "crserver@${inst_name}.service"; then
        log_info "Сервер хранилища ЗАПУЩЕН"
    else
        log_error "Не удалось запустить (exit=${start_rc})"
        echo "  Лог: journalctl -u crserver@${inst_name} -n 50"
        return 1
    fi

    if ss -tlnH 2>/dev/null | awk -v p=":${inst_port}" '$4 ~ p"$" {found=1} END {exit !found}'; then
        log_info "Порт ${inst_port} слушается"
    fi

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  УСТАНОВКА ЗАВЕРШЕНА${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    local IP_ADDR
    IP_ADDR=$(get_primary_ip)
    echo ""
    echo "  Инстанс:  ${inst_name}"
    echo "  Версия:   ${target_ver}"
    echo "  Адрес:    tcp://${IP_ADDR}:${inst_port}/<имя_хранилища>"
    echo ""
    read -rp "  Нажмите Enter..." _
}

do_full_uninstall() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${RED}  Полное удаление сервера хранилища 1С${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""

    instance_list
    get_installed_versions

    echo "  Что будет удалено:"
    if [[ ${#INSTANCES[@]} -gt 0 ]]; then
        local n
        for n in "${INSTANCES[@]}"; do
            echo "    • Инстанс ${n}"
        done
    fi
    if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
        local v
        for v in "${INSTALLED_VERSIONS[@]}"; do
            echo "    • Пакеты версии ${v}"
        done
    fi
    echo "    • systemd-template crserver@.service"
    echo "    • Правила файрвола (цепочки)"
    echo "    • ${ETC_DIR}/"
    echo ""
    echo -e "  ${YELLOW}Каталоги хранилищ /var/1c/repo-* НЕ удаляются${NC}"
    echo -e "  ${YELLOW}Каталог пакетов ${PACKAGES_DIR} НЕ удаляется${NC}"
    echo ""
    read -rp "  Введите 'DELETE' для подтверждения: " answer
    if [[ "$answer" != "DELETE" ]]; then
        log_warn "Отменено"
        return
    fi

    # Под set -e ошибка любой команды прервала бы цикл и оставила
    # недочищенные инстансы. Переход в режим "ошибки игнорируются":
    # uninstall — уже terminal-операция, и лучше дочистить хоть что-то,
    # чем застрять на середине.
    set +e
    local n port
    for n in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
        systemctl stop "crserver@${n}.service" 2>/dev/null
        systemctl disable "crserver@${n}.service" 2>/dev/null
        port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null)
        [[ -n "$port" ]] && remove_input_for_port "$port"
        cleanup_instance_chain "$n"
    done
    set -e

    rm -f "$SERVICE_TEMPLATE_FILE"
    systemctl daemon-reload

    # Старый юнит на всякий случай
    if [[ -f "$LEGACY_SERVICE_FILE" ]]; then
        systemctl stop crserver.service 2>/dev/null || true
        systemctl disable crserver.service 2>/dev/null || true
        rm -f "$LEGACY_SERVICE_FILE"
    fi

    local v
    for v in "${INSTALLED_VERSIONS[@]+"${INSTALLED_VERSIONS[@]}"}"; do
        log_step "Удаление версии ${v}..."
        dpkg --purge "1c-enterprise-${v}-crs"    2>/dev/null || true
        dpkg --purge "1c-enterprise-${v}-ws"     2>/dev/null || true
        dpkg --purge "1c-enterprise-${v}-server" 2>/dev/null || true
        dpkg --purge "1c-enterprise-${v}-common" 2>/dev/null || true
    done
    apt-get autoremove -y -qq > /dev/null 2>&1 || true
    log_info "Пакеты удалены"

    cleanup_firewall
    log_info "Правила файрвола очищены"

    rm -rf "$ETC_DIR"

    echo ""
    log_info "Удаление завершено"
    echo -e "  ${YELLOW}Каталоги хранилищ /var/1c/repo-* сохранены. Удалите вручную если не нужны.${NC}"
    echo ""
}

# ============================================================================
#  УПРАВЛЕНИЕ СЛУЖБАМИ — МЕНЮ ВЕРХНЕГО УРОВНЯ
# ============================================================================

do_service_menu() {
    if ! require_instance; then
        return
    fi
    SELECTED_INSTANCE="$INST_NAME"
    do_instance_service
}

# ============================================================================
#  ХРАНИЛИЩА КОНФИГУРАЦИЙ (REPO_DIR конкретного инстанса)
# ============================================================================

# Имя хранилища: только латиница/цифры/_/- , 1..64 символа
validate_repo_name() {
    local name="$1"
    [[ -z "$name" ]] && return 1
    [[ ${#name} -gt 64 ]] && return 1
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    return 0
}

# Заполняет массив (имя массива в $1) подкаталогами в INST_REPO_DIR
get_repo_list() {
    local _out_var="$1"
    local _result=()
    if [[ -d "$INST_REPO_DIR" ]]; then
        local _dir
        for _dir in "$INST_REPO_DIR"/*/; do
            [[ -d "$_dir" ]] || continue
            _result+=("$(basename "$_dir")")
        done
    fi
    local -n _ref="$_out_var"
    _ref=("${_result[@]+"${_result[@]}"}")
}

repo_looks_initialized() {
    local dir="$1"
    [[ -f "$dir/1cv8ddb.lst" ]] && return 0
    [[ -d "$dir/cache" ]]      && return 0
    [[ -d "$dir/data" ]]       && return 0
    [[ -f "$dir/v8inforeg.lst" ]] && return 0
    return 1
}

do_repo_menu() {
    if ! require_instance; then
        return
    fi
    while true; do
        local repos=()
        get_repo_list repos
        local ip_addr
        ip_addr=$(get_primary_ip)

        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Хранилища (инстанс: ${CYAN}${INST_NAME}${NC})"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo "  Каталог: ${INST_REPO_DIR}"
        echo "  Порт:    ${INST_PORT}"
        echo ""

        if [[ ${#repos[@]} -eq 0 ]]; then
            echo "  (хранилищ нет)"
        else
            echo "  Существующие:"
            echo "  ─────────────────────────────────────────────"
            local idx=0 r size status
            for r in "${repos[@]}"; do
                idx=$((idx + 1))
                size=$(du -sh "${INST_REPO_DIR}/${r}" 2>/dev/null | awk '{print $1}')
                if repo_looks_initialized "${INST_REPO_DIR}/${r}"; then
                    status="${GREEN}init${NC}"
                else
                    status="${YELLOW}пусто${NC}"
                fi
                echo -e "    ${idx}) ${r}  [${size:-?}]  (${status})"
                echo "       → tcp://${ip_addr}:${INST_PORT}/${r}"
            done
        fi

        echo ""
        echo "  1) Подробный список"
        echo "  2) Подготовить новое хранилище"
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
        dir="${INST_REPO_DIR}/${r}"
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
    echo "  Подключение: tcp://${ip_addr}:${INST_PORT}/<имя>"
}

do_repo_create() {
    echo ""
    read -rp "  Имя нового хранилища: " name
    if ! validate_repo_name "$name"; then
        log_error "Недопустимое имя"
        return 1
    fi
    local dir="${INST_REPO_DIR}/${name}"
    if [[ -e "$dir" ]]; then
        log_error "Уже существует: ${dir}"
        return 1
    fi

    detect_1c_user
    if [[ -z "${SVC_USER:-}" || -z "${SVC_GROUP:-}" ]]; then
        log_error "Не определён пользователь usr1cv8 — выполните установку"
        return 1
    fi

    mkdir -p "$dir"
    chown "${SVC_USER}:${SVC_GROUP}" "$dir"
    chmod 750 "$dir"
    log_info "Каталог создан: ${dir}"

    echo ""
    echo "  Это пустая ЗАГОТОВКА. Структура создаётся конфигуратором при"
    echo "  первом подключении: Конфигурация → Хранилище конфигурации → Создать."
    local ip_addr
    ip_addr=$(get_primary_ip)
    echo "    Адрес: tcp://${ip_addr}:${INST_PORT}/${name}"
}

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
    local dir="${INST_REPO_DIR}/${repo_chosen}"
    local ip_addr
    ip_addr=$(get_primary_ip)

    echo ""
    echo "  Хранилище '${repo_chosen}' (инстанс ${INST_NAME})"
    echo "  ─────────────────────────────────────────────"
    echo "    Путь:       ${dir}"
    echo "    Адрес:      tcp://${ip_addr}:${INST_PORT}/${repo_chosen}"
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

    if command -v ss >/dev/null 2>&1; then
        local conns
        # 4-я колонка ss -tn — Local Address:Port. Точное совпадение по порту.
        conns=$(ss -tnH 2>/dev/null | awk -v p=":${INST_PORT}" '$1=="ESTAB" && $4 ~ p"$"' | wc -l)
        echo "    Активных подключений к порту ${INST_PORT}: ${conns}"
    fi
}

do_repo_rename() {
    local repo_chosen=""
    _select_repo_interactive || return
    local old_name="$repo_chosen"
    local old_dir="${INST_REPO_DIR}/${old_name}"

    echo ""
    log_warn "Переименование разорвёт URL подключения у клиентов!"
    echo "    Было:   tcp://...:${INST_PORT}/${old_name}"
    read -rp "  Новое имя: " new_name
    if ! validate_repo_name "$new_name"; then
        log_error "Недопустимое имя"
        return 1
    fi
    if [[ "$new_name" == "$old_name" ]]; then
        log_warn "Имя не изменилось"
        return
    fi
    local new_dir="${INST_REPO_DIR}/${new_name}"
    if [[ -e "$new_dir" ]]; then
        log_error "Уже существует"
        return 1
    fi

    local unit="crserver@${INST_NAME}.service"
    local was_active=0
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        was_active=1
        log_step "Остановка ${unit}..."
        systemctl stop "$unit" 2>/dev/null || true
        sleep 1
    fi

    if ! mv "$old_dir" "$new_dir"; then
        log_error "mv не удался"
        if [[ $was_active -eq 1 ]]; then
            systemctl start "$unit" 2>/dev/null || true
        fi
        return 1
    fi

    if [[ $was_active -eq 1 ]]; then
        systemctl start "$unit" 2>/dev/null || \
            log_warn "Служба не стартовала — journalctl -u ${unit}"
    fi

    local ip_addr
    ip_addr=$(get_primary_ip)
    log_info "Переименовано: ${old_name} → ${new_name}"
    echo "    Стало: tcp://${ip_addr}:${INST_PORT}/${new_name}"
}

do_repo_delete() {
    local repo_chosen=""
    _select_repo_interactive || return
    local name="$repo_chosen"
    local dir="${INST_REPO_DIR}/${name}"

    echo ""
    echo "  Будет УДАЛЁН каталог:"
    echo "    ${dir}"
    echo "  Размер: $(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    echo ""
    log_warn "Это необратимо. Рекомендуется сначала сделать бэкап."
    echo ""
    read -rp "  Введите имя хранилища '${name}' для подтверждения: " confirm
    if [[ "$confirm" != "$name" ]]; then
        log_warn "Отменено (имя не совпало)"
        return
    fi

    local unit="crserver@${INST_NAME}.service"
    local was_active=0
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        was_active=1
        log_step "Остановка ${unit}..."
        systemctl stop "$unit" 2>/dev/null || true
        sleep 1
    fi

    if ! rm -rf "$dir"; then
        log_error "rm -rf завершился с ошибкой"
        if [[ $was_active -eq 1 ]]; then
            systemctl start "$unit" 2>/dev/null || true
        fi
        return 1
    fi
    log_info "Удалено: ${name}"

    if [[ $was_active -eq 1 ]]; then
        systemctl start "$unit" 2>/dev/null || \
            log_warn "Служба не стартовала — journalctl -u ${unit}"
    fi
}

do_repo_backup() {
    local repo_chosen=""
    _select_repo_interactive || return
    local name="$repo_chosen"
    local src="${INST_REPO_DIR}/${name}"

    mkdir -p "$BACKUP_DIR"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local archive="${BACKUP_DIR}/${INST_NAME}_repo_${name}_${timestamp}.tar.gz"

    # Ctrl+C во время tar — удалить неполный архив
    trap 'rm -f "$archive"; trap - INT TERM; exit 130' INT TERM

    local stop_service=0
    echo ""
    read -rp "  Остановить службу на время бэкапа (рекомендуется)? (Y/n): " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
        stop_service=1
    fi

    local unit="crserver@${INST_NAME}.service"
    local was_active=0
    if [[ $stop_service -eq 1 ]] && systemctl is-active --quiet "$unit" 2>/dev/null; then
        was_active=1
        log_step "Остановка ${unit}..."
        systemctl stop "$unit" 2>/dev/null || true
        sleep 1
    fi

    log_step "Создание архива ${archive}..."
    if ! tar -czf "$archive" -C "$INST_REPO_DIR" "$name" 2>/tmp/crserver-tar.log; then
        log_error "tar завершился с ошибкой:"
        tail -5 /tmp/crserver-tar.log | sed 's/^/    /'
        rm -f /tmp/crserver-tar.log "$archive"
        trap - INT TERM
        if [[ $was_active -eq 1 ]]; then
            systemctl start "$unit" 2>/dev/null || true
        fi
        return 1
    fi
    rm -f /tmp/crserver-tar.log

    log_step "Проверка целостности архива..."
    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        log_error "Архив повреждён (verify не прошёл) — удаляю"
        rm -f "$archive"
        trap - INT TERM
        if [[ $was_active -eq 1 ]]; then
            systemctl start "$unit" 2>/dev/null || true
        fi
        return 1
    fi
    trap - INT TERM

    local size
    size=$(du -sh "$archive" 2>/dev/null | awk '{print $1}')
    log_info "Бэкап создан: ${archive} [${size:-?}]"

    if [[ $was_active -eq 1 ]]; then
        systemctl start "$unit" 2>/dev/null || \
            log_warn "Служба не стартовала — journalctl -u ${unit}"
    fi
}

do_repo_restore() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warn "Каталог бэкапов не существует: ${BACKUP_DIR}"
        return
    fi

    # Бэкапы для текущего инстанса: <inst>_repo_<имя>_<ts>.tar.gz
    local backups=()
    local f
    for f in "$BACKUP_DIR"/${INST_NAME}_repo_*.tar.gz; do
        [[ -f "$f" ]] && backups+=("$f")
    done
    if [[ ${#backups[@]} -eq 0 ]]; then
        log_warn "Нет бэкапов отдельных хранилищ для инстанса ${INST_NAME}"
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
    # Все записи архива должны лежать в одном top-level каталоге с допустимым именем.
    local top_dirs name
    top_dirs=$(tar -tzf "$archive" 2>/dev/null | awk -F/ 'NF>0 && $1!="" {print $1}' | sort -u)
    if [[ -z "$top_dirs" ]]; then
        log_error "Не удалось прочитать содержимое архива"
        return 1
    fi
    if [[ $(printf '%s\n' "$top_dirs" | wc -l) -ne 1 ]]; then
        log_error "Архив содержит несколько каталогов верхнего уровня — небезопасно для restore:"
        printf '%s\n' "$top_dirs" | sed 's/^/    /'
        return 1
    fi
    name="$top_dirs"
    if ! validate_repo_name "$name"; then
        log_error "Имя каталога в архиве не похоже на имя хранилища: '${name}'"
        return 1
    fi

    echo ""
    echo "  Архив:      $(basename "$archive")"
    echo "  Хранилище:  ${name}"
    local target="${INST_REPO_DIR}/${name}"
    if [[ -e "$target" ]]; then
        echo ""
        log_warn "Хранилище '${name}' уже существует и БУДЕТ ЗАМЕНЕНО"
        read -rp "  Введите '${name}' для подтверждения замены: " confirm
        if [[ "$confirm" != "$name" ]]; then
            log_warn "Отменено"
            return
        fi
    fi

    local unit="crserver@${INST_NAME}.service"
    local was_active=0
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        was_active=1
        log_step "Остановка ${unit}..."
        systemctl stop "$unit" 2>/dev/null || true
        sleep 1
    fi

    local rollback_dir=""
    if [[ -e "$target" ]]; then
        rollback_dir="${target}.pre-restore.$(date +%s)"
        mv "$target" "$rollback_dir"
    fi

    log_step "Распаковка архива..."
    if ! tar -xzf "$archive" -C "$INST_REPO_DIR" 2>/tmp/crserver-tar.log; then
        log_error "Ошибка распаковки:"
        tail -5 /tmp/crserver-tar.log | sed 's/^/    /'
        rm -f /tmp/crserver-tar.log
        if [[ -n "$rollback_dir" ]]; then
            log_warn "Восстанавливаю предыдущее состояние..."
            rm -rf "$target" 2>/dev/null || true
            mv "$rollback_dir" "$target"
        fi
        if [[ $was_active -eq 1 ]]; then
            systemctl start "$unit" 2>/dev/null || true
        fi
        return 1
    fi
    rm -f /tmp/crserver-tar.log

    detect_1c_user
    if [[ -n "${SVC_USER:-}" && -n "${SVC_GROUP:-}" ]]; then
        chown -R "${SVC_USER}:${SVC_GROUP}" "$target"
    fi

    log_info "Восстановлено: ${name}"
    if [[ -n "$rollback_dir" ]]; then
        echo "  Прежний вариант сохранён: ${rollback_dir}"
    fi

    if [[ $was_active -eq 1 ]]; then
        systemctl start "$unit" 2>/dev/null || \
            log_warn "Служба не стартовала — journalctl -u ${unit}"
    fi
}

do_repo_check() {
    local repo_chosen=""
    _select_repo_interactive || return
    local name="$repo_chosen"
    local dir="${INST_REPO_DIR}/${name}"
    if [[ ! -d "$dir" ]]; then
        log_error "Каталог хранилища не существует: ${dir}"
        return 1
    fi
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
        issues=$((issues + 1))
    fi

    local foreign
    foreign=$(find "$dir" ! -user "$SVC_USER" 2>/dev/null | head -3)
    if [[ -n "$foreign" ]]; then
        log_warn "Найдены файлы НЕ принадлежащие ${SVC_USER}:"
        echo "$foreign" | sed 's/^/    /'
        issues=$((issues + 1))
    fi

    local locks
    locks=$(find "$dir" -maxdepth 2 -name "*.lck" -o -name "*.lock" 2>/dev/null | head -3)
    if [[ -n "$locks" ]]; then
        log_warn "Найдены lock-файлы:"
        echo "$locks" | sed 's/^/    /'
    fi

    echo ""
    if [[ $issues -eq 0 ]]; then
        log_info "Проблем не обнаружено"
    else
        log_warn "Обнаружено проблем: ${issues}"
    fi
}

# ============================================================================
#  ФАЙРВОЛ
# ============================================================================
#
# МОДЕЛЬ:
#   * Цепочка CRSERVER — общая для ВСЕХ инстансов (глобальный whitelist).
#     Структура: ACCEPT 127.0.0.1; <разрешённые IP/подсети>; финальное
#     полиси-правило ACCEPT (open) или DROP (whitelist).
#   * Цепочка CRSERVER-<имя> — опциональные пер-инстанс правила. Если в
#     ней есть хотя бы одно ACCEPT, INPUT-правило для порта прыгает И в
#     CRSERVER, И в CRSERVER-<имя>. Если цепочки нет — только в CRSERVER.
#   * INPUT для каждого порта инстанса: -p tcp --dport <port> -j CRSERVER
#     (плюс -j CRSERVER-<имя> при наличии).

setup_firewall_chain() {
    # Создаёт цепочку CRSERVER если её нет. Существующую НЕ трогаем —
    # иначе при пересоздании инстанса/реустановке потерялись бы whitelist-
    # настройки администратора (см. фикс v2.0.2).
    if ! iptables -L "$IPTABLES_CHAIN" -n &>/dev/null; then
        iptables -N "$IPTABLES_CHAIN"
        iptables -A "$IPTABLES_CHAIN" -s 127.0.0.1 -j ACCEPT
        iptables -A "$IPTABLES_CHAIN" -j ACCEPT
        save_iptables
    fi
}

ensure_firewall_chain() {
    setup_firewall_chain
}

cleanup_firewall() {
    # Удаляем INPUT-правила всех инстансов
    instance_list
    local n port
    for n in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
        port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
        [[ -n "$port" ]] && remove_input_for_port "$port"
        cleanup_instance_chain "$n"
    done
    iptables -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -X "$IPTABLES_CHAIN" 2>/dev/null || true
    save_iptables
}

save_iptables() {
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save > /dev/null 2>&1 || true
    fi
}

# Добавляет INPUT-правила для порта (CRSERVER + CRSERVER-<инст>, если цепочка есть).
add_input_for_port() {
    local port="$1"
    [[ -z "$port" ]] && return 1
    ensure_firewall_chain
    iptables -C INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN" 2>/dev/null || \
        iptables -A INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN"
    save_iptables
    return 0
}

remove_input_for_port() {
    local port="$1"
    [[ -z "$port" ]] && return 1
    while iptables -C INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN" 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "$port" -j "$IPTABLES_CHAIN" 2>/dev/null || break
    done
    # Per-instance ссылки удаляются в cleanup_instance_chain — здесь только общая
    save_iptables
    return 0
}

chain_rule_count() {
    # grep -c при отсутствии совпадений возвращает 0 и exit 1.
    # Под set -e || true даёт пустой stdout — это ловушка для вызывающего.
    # Подавляем exit-code через awk-обёртку, всегда печатаем число.
    iptables -S "$IPTABLES_CHAIN" 2>/dev/null | awk '/^-A / {n++} END {print n+0}'
}

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

set_policy_mode() {
    local mode="$1"
    ensure_firewall_chain
    iptables -D "$IPTABLES_CHAIN" -j ACCEPT 2>/dev/null || true
    iptables -D "$IPTABLES_CHAIN" -j DROP   2>/dev/null || true
    case "$mode" in
        whitelist) iptables -A "$IPTABLES_CHAIN" -j DROP ;;
        open)      iptables -A "$IPTABLES_CHAIN" -j ACCEPT ;;
    esac
    save_iptables
}

validate_ip() {
    local ip="$1"
    local addr mask
    if [[ "$ip" == */* ]]; then
        addr="${ip%/*}"
        mask="${ip#*/}"
        [[ "$mask" =~ ^[0-9]+$ ]] || return 1
        (( mask >= 0 && mask <= 32 )) || return 1
    else
        addr="$ip"
    fi
    [[ "$addr" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    local i
    for i in 1 2 3 4; do
        local oct="${BASH_REMATCH[$i]}"
        # Запрет ведущих нулей (кроме одиночного "0") и значений > 255
        [[ "$oct" =~ ^0[0-9]+$ ]] && return 1
        (( oct >= 0 && oct <= 255 )) || return 1
    done
    return 0
}

add_allowed_ip() {
    local ip="$1"
    ensure_firewall_chain
    if iptables -C "$IPTABLES_CHAIN" -s "$ip" -j ACCEPT 2>/dev/null; then
        log_warn "IP $ip уже в списке"
        return
    fi
    local total
    total=$(chain_rule_count)
    total="${total:-0}"
    if (( total >= 1 )); then
        # Вставляем перед последним правилом (финальная политика ACCEPT/DROP).
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

# Per-instance цепочка: CRSERVER-<имя>. Структура такая же, но без финального
# полиси-правила (политика общая в CRSERVER).
# iptables ограничивает имя цепочки 28 символами. Префикс "CRSERVER-" — 9,
# значит на имя инстанса в этом контексте остаётся 19. instance_name_valid
# допускает до 32 — для пер-инстанс цепочки требуется более жёсткая проверка.
IPTABLES_CHAIN_MAX_LEN=28

instance_chain_name() {
    local name="$1"
    if ! instance_name_valid "$name"; then
        log_error "instance_chain_name: невалидное имя '${name}'" >&2
        return 1
    fi
    local chain="CRSERVER-${name}"
    if (( ${#chain} > IPTABLES_CHAIN_MAX_LEN )); then
        log_error "Имя инстанса '${name}' слишком длинное для пер-инстанс цепочки iptables (макс. имя: $((IPTABLES_CHAIN_MAX_LEN - 9)) символов)" >&2
        return 1
    fi
    echo "$chain"
}

setup_instance_chain() {
    local name="$1"
    if ! instance_name_valid "$name"; then
        log_error "setup_instance_chain: невалидное имя '${name}'"
        return 1
    fi
    local chain
    chain=$(instance_chain_name "$name") || return 1
    iptables -N "$chain" 2>/dev/null || iptables -F "$chain"
    iptables -A "$chain" -s 127.0.0.1 -j ACCEPT
    save_iptables
}

cleanup_instance_chain() {
    local name="$1"
    if ! instance_name_valid "$name"; then
        log_warn "cleanup_instance_chain: пропускаю — невалидное имя '${name}'"
        return 0
    fi
    local chain port
    chain=$(instance_chain_name "$name") || return 1
    port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${name}.conf" 2>/dev/null || true)
    if [[ -n "$port" ]]; then
        while iptables -C INPUT -p tcp --dport "$port" -j "$chain" 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$port" -j "$chain" 2>/dev/null || break
        done
    fi
    iptables -F "$chain" 2>/dev/null || true
    iptables -X "$chain" 2>/dev/null || true
    save_iptables
}

add_allowed_ip_for_instance() {
    local name="$1" ip="$2"
    if ! instance_name_valid "$name"; then
        log_error "add_allowed_ip_for_instance: невалидное имя '${name}'"
        return 1
    fi
    local chain
    chain=$(instance_chain_name "$name") || return 1
    if ! iptables -L "$chain" -n &>/dev/null; then
        setup_instance_chain "$name"
        # Подцепляем INPUT
        local port
        port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${name}.conf" 2>/dev/null || true)
        if [[ -n "$port" ]]; then
            iptables -C INPUT -p tcp --dport "$port" -j "$chain" 2>/dev/null || \
                iptables -I INPUT 1 -p tcp --dport "$port" -j "$chain"
        fi
    fi
    if iptables -C "$chain" -s "$ip" -j ACCEPT 2>/dev/null; then
        log_warn "IP $ip уже в списке инстанса"
        return
    fi
    iptables -A "$chain" -s "$ip" -j ACCEPT
    save_iptables
}

do_access_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Файрвол (общая цепочка ${IPTABLES_CHAIN})"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""

        local mode
        mode=$(current_policy_mode)
        echo -n "  Режим: "
        case "$mode" in
            whitelist) echo -e "${YELLOW}БЕЛЫЙ СПИСОК${NC} (доступ только для разрешённых IP)" ;;
            open)      echo -e "${GREEN}ОТКРЫТЫЙ${NC} (порты доступны всем)" ;;
            *)         echo -e "${RED}не настроен${NC}" ;;
        esac

        # Перечисляем порты инстансов
        instance_list
        if [[ ${#INSTANCES[@]} -gt 0 ]]; then
            echo ""
            echo "  Защищённые порты:"
            local n p
            for n in "${INSTANCES[@]}"; do
                p=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
                local protected="нет"
                if iptables -C INPUT -p tcp --dport "$p" -j "$IPTABLES_CHAIN" 2>/dev/null; then
                    protected="да"
                fi
                echo "    ${n}  port=${p}  → CRSERVER: ${protected}"
            done
        fi

        echo ""
        echo "  Правила в общей цепочке:"
        echo "  ─────────────────────────────────────────────"
        if iptables -L "$IPTABLES_CHAIN" -n --line-numbers 2>/dev/null | grep -qE '^[0-9]+ +(ACCEPT|DROP)'; then
            local line num action src color desc
            while IFS= read -r line; do
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
            echo "    (цепочка не создана)"
        fi

        echo ""
        echo "  1) Добавить разрешённый IP (общий список)"
        echo "  2) Добавить разрешённую подсеть (общий список)"
        echo "  3) Включить режим белого списка"
        echo "  4) Открыть порты для всех (снять ограничения)"
        echo "  5) Удалить правило по номеру"
        echo "  6) Показать мой внешний IP"
        echo "  7) Пер-инстанс правила (CRSERVER-<имя>)"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1)
                read -rp "  IP-адрес: " ip
                if validate_ip "$ip"; then
                    add_allowed_ip "$ip"
                    log_info "IP $ip добавлен"
                else
                    log_error "Некорректный IP"
                fi
                ;;
            2)
                read -rp "  Подсеть (например 192.168.1.0/24): " subnet
                if [[ "$subnet" == */* ]] && validate_ip "$subnet"; then
                    add_allowed_ip "$subnet"
                    log_info "Подсеть $subnet добавлена"
                else
                    log_error "Некорректный формат"
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
                log_info "Открыто для всех"
                ;;
            5)
                read -rp "  Номер правила: " rule_num
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
                read -rp "  Нажмите Enter..." _
                ;;
            7) do_instance_firewall_menu ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

do_instance_firewall_menu() {
    if ! select_instance_interactive; then
        return
    fi
    local name="$SELECTED_INSTANCE"
    local chain
    chain=$(instance_chain_name "$name")

    while true; do
        echo ""
        echo -e "${BOLD}  Файрвол инстанса '${name}' (цепочка ${chain})${NC}"
        echo "  ─────────────────────────────────────────────"
        if iptables -L "$chain" -n --line-numbers 2>/dev/null | grep -qE '^[0-9]+ +ACCEPT'; then
            iptables -L "$chain" -n --line-numbers 2>/dev/null | grep -E '^[0-9]+ +ACCEPT' | sed 's/^/    /'
        else
            echo "    (цепочка не настроена или пуста)"
        fi
        echo ""
        echo "  1) Добавить IP в пер-инстанс whitelist"
        echo "  2) Удалить правило по номеру"
        echo "  3) Удалить пер-инстанс цепочку полностью"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " ch
        case $ch in
            1)
                read -rp "  IP/подсеть: " ip
                if validate_ip "$ip"; then
                    add_allowed_ip_for_instance "$name" "$ip"
                    log_info "Добавлено в ${chain}: ${ip}"
                else
                    log_error "Некорректный IP"
                fi
                ;;
            2)
                read -rp "  Номер: " rn
                if [[ "$rn" =~ ^[0-9]+$ ]]; then
                    if iptables -D "$chain" "$rn" 2>/dev/null; then
                        save_iptables
                        log_info "Удалено правило #${rn}"
                    else
                        log_error "Не удалось"
                    fi
                fi
                ;;
            3)
                cleanup_instance_chain "$name"
                log_info "Цепочка ${chain} удалена"
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

# ============================================================================
#  БЭКАП / ВОССТАНОВЛЕНИЕ
# ============================================================================

do_backup_menu() {
    if ! require_instance; then
        return
    fi
    while true; do
        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "  Бэкап и восстановление (инстанс: ${CYAN}${INST_NAME}${NC})"
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""

        local backup_files=()
        if [[ -d "$BACKUP_DIR" ]]; then
            local f
            for f in "$BACKUP_DIR"/${INST_NAME}_*.tar.gz; do
                [[ -f "$f" ]] && backup_files+=("$f")
            done
        fi

        if [[ ${#backup_files[@]} -gt 0 ]]; then
            echo "  Бэкапы инстанса:"
            echo "  ─────────────────────────────────────────────"
            local idx=0 size
            for f in "${backup_files[@]}"; do
                idx=$((idx + 1))
                size=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
                echo "    ${idx}) $(basename "$f")  [${size:-?}]"
            done
            echo ""
        else
            echo "  Бэкапов инстанса ${INST_NAME} пока нет"
            echo ""
        fi

        echo "  1) Создать бэкап всех хранилищ инстанса"
        echo "  2) Восстановить инстанс из бэкапа"
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
                        find "$BACKUP_DIR" -maxdepth 1 -name "${INST_NAME}_*.tar.gz" -mtime +"$days" -delete 2>/dev/null
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
                    read -rp "  Номер бэкапа (или 0 для отмены): " num
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

# Бэкап всего REPO_DIR текущего инстанса
do_backup() {
    if [[ -z "${INST_NAME:-}" ]]; then
        log_error "do_backup: контекст инстанса не задан"
        return 1
    fi
    if [[ ! -d "$INST_REPO_DIR" ]]; then
        log_error "Каталог хранилищ не существует: ${INST_REPO_DIR}"
        return 1
    fi

    mkdir -p "$BACKUP_DIR"
    local timestamp backup_file
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_file="${BACKUP_DIR}/${INST_NAME}_${timestamp}.tar.gz"

    # Ctrl+C / SIGTERM во время tar — удалить недописанный архив.
    trap 'rm -f "$backup_file"; trap - INT TERM; exit 130' INT TERM

    log_step "Создание бэкапа инстанса ${INST_NAME}..."
    if ! tar -czf "$backup_file" \
            -C "$(dirname "$INST_REPO_DIR")" "$(basename "$INST_REPO_DIR")" \
            --ignore-failed-read 2>/tmp/crserver-tar.log; then
        log_error "Создание бэкапа не удалось:"
        tail -5 /tmp/crserver-tar.log | sed 's/^/    /'
        rm -f /tmp/crserver-tar.log "$backup_file"
        trap - INT TERM
        return 1
    fi
    rm -f /tmp/crserver-tar.log

    log_step "Проверка целостности архива..."
    if ! tar -tzf "$backup_file" >/dev/null 2>&1; then
        log_error "Архив повреждён (verify не прошёл) — удаляю"
        rm -f "$backup_file"
        trap - INT TERM
        return 1
    fi
    trap - INT TERM

    local size
    size=$(du -sh "$backup_file" 2>/dev/null | awk '{print $1}')
    log_info "Бэкап создан: ${backup_file} [${size:-?}]"
    return 0
}

do_restore() {
    if [[ -z "${INST_NAME:-}" ]]; then
        log_error "do_restore: контекст инстанса не задан"
        return 1
    fi
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_warn "Нет каталога бэкапов: ${BACKUP_DIR}"
        return
    fi

    local files=()
    local f
    for f in "$BACKUP_DIR"/${INST_NAME}_*.tar.gz; do
        [[ -f "$f" ]] && files+=("$f")
    done
    if [[ ${#files[@]} -eq 0 ]]; then
        log_warn "Нет бэкапов инстанса ${INST_NAME}"
        return
    fi

    echo ""
    echo "  Доступные бэкапы:"
    local idx=0
    for f in "${files[@]}"; do
        idx=$((idx + 1))
        echo "    ${idx}) $(basename "$f")"
    done
    echo ""
    read -rp "  Номер бэкапа: " num
    if [[ "$num" == "0" || -z "$num" ]]; then
        return
    fi
    if ! [[ "$num" =~ ^[0-9]+$ ]] || (( num < 1 || num > ${#files[@]} )); then
        log_error "Неверный номер"
        return 1
    fi

    local selected="${files[$((num - 1))]}"
    echo ""
    log_warn "Это перезапишет ${INST_REPO_DIR}!"
    read -rp "  Продолжить? (y/N): " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        return
    fi

    local unit="crserver@${INST_NAME}.service"
    local was_active=0
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        was_active=1
    fi
    systemctl stop "$unit" 2>/dev/null || true

    if ! tar -xzf "$selected" -C "$(dirname "$INST_REPO_DIR")" 2>/tmp/crserver-tar.log; then
        log_error "Ошибка распаковки:"
        tail -5 /tmp/crserver-tar.log | sed 's/^/    /'
        rm -f /tmp/crserver-tar.log
        if [[ $was_active -eq 1 ]]; then
            systemctl start "$unit" 2>/dev/null || true
        fi
        return 1
    fi
    rm -f /tmp/crserver-tar.log

    detect_1c_user
    if [[ -n "${SVC_USER:-}" && -n "${SVC_GROUP:-}" ]]; then
        chown -R "${SVC_USER}:${SVC_GROUP}" "$INST_REPO_DIR"
    fi

    if [[ $was_active -eq 1 ]]; then
        if ! systemctl start "$unit" 2>/dev/null; then
            log_error "Служба не запустилась — journalctl -u ${unit}"
        fi
    fi
    log_info "Восстановлено: $(basename "$selected")"
}

do_setup_cron_backup() {
    if [[ -z "${INST_NAME:-}" ]]; then
        log_error "do_setup_cron_backup: контекст инстанса не задан"
        return 1
    fi
    local cron_script="/usr/local/bin/crserver-backup-${INST_NAME}.sh"
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
INST="${INST_NAME}"
BACKUP_DIR="${BACKUP_DIR}"
REPO_DIR="${INST_REPO_DIR}"
KEEP_DAYS="${keep_days}"

mkdir -p "\$BACKUP_DIR"
timestamp=\$(date +%Y%m%d_%H%M%S)
archive="\${BACKUP_DIR}/\${INST}_\${timestamp}.tar.gz"
log_file="\${BACKUP_DIR}/.last-backup-\${INST}.log"
if ! tar -czf "\$archive" \\
        -C "\$(dirname "\$REPO_DIR")" "\$(basename "\$REPO_DIR")" \\
        --ignore-failed-read 2>"\$log_file"; then
    logger -t crserver-backup "FAILED \${INST} at \${timestamp}, see \${log_file}"
    rm -f "\$archive"
    exit 1
fi
if ! tar -tzf "\$archive" >/dev/null 2>>"\$log_file"; then
    logger -t crserver-backup "CORRUPT \${INST} at \${timestamp}, see \${log_file}"
    rm -f "\$archive"
    exit 1
fi
find "\$BACKUP_DIR" -maxdepth 1 -name "\${INST}_*.tar.gz" -mtime "+\${KEEP_DAYS}" -delete 2>/dev/null
EOFCRON

    chmod +x "$cron_script"
    local cron_line="0 3 * * * ${cron_script}"
    (crontab -l 2>/dev/null | grep -F -v "$cron_script"; echo "$cron_line") | crontab -

    log_info "Автобэкап инстанса ${INST_NAME}: ежедневно в 03:00, хранение ${keep_days} дней"
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
        echo "  2) Список хранилищ всех инстансов"
        echo "  3) Проверка подключения к порту инстанса"
        echo "  4) Дисковое пространство"
        echo "  5) Открытые порты 1С"
        echo "  6) Диагностика инстанса"
        echo ""
        echo "  0) ← Назад"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1) echo ""; do_system_info; read -rp "  Нажмите Enter..." _ ;;
            2) echo ""; do_list_all_repos; read -rp "  Нажмите Enter..." _ ;;
            3)
                if ! require_instance; then continue; fi
                read -rp "  IP для проверки (Enter — localhost): " test_ip
                test_ip="${test_ip:-127.0.0.1}"
                echo ""
                if timeout 3 bash -c "echo >/dev/tcp/${test_ip}/${INST_PORT}" 2>/dev/null; then
                    log_info "Порт ${INST_PORT} на ${test_ip} доступен"
                else
                    log_error "Порт ${INST_PORT} на ${test_ip} недоступен"
                fi
                read -rp "  Нажмите Enter..." _
                ;;
            4)
                echo ""
                echo "  Дисковое пространство:"
                echo "  ─────────────────────────────────────────────"
                df -h / | tail -1 | awk '{printf "    Диск:      %s из %s (использовано %s)\n", $3, $2, $5}'
                instance_list
                local n p
                for n in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
                    p=$(awk -F'"' '/^REPO_DIR=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
                    [[ -d "$p" ]] && echo "    ${n}: $(du -sh "$p" 2>/dev/null | awk '{print $1}')  ($p)"
                done
                [[ -d "$BACKUP_DIR" ]]   && echo "    Бэкапы:    $(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
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
            6)
                if require_instance; then
                    echo ""; do_diagnose; read -rp "  Нажмите Enter..." _
                fi
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

do_system_info() {
    detect_1c_user
    get_installed_versions
    get_available_versions
    instance_list

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
    echo -n "    Установлено:   "
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
    echo ""
    echo "  Инстансы (${#INSTANCES[@]}):"
    echo "  ─────────────────────────────────────────────"
    local n status_text def
    def=$(instance_default)
    for n in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
        status_text=$(instance_status "$n")
        local mark=""
        [[ "$n" == "$def" ]] && mark="  (default)"
        echo "    ${n}  [${status_text}]${mark}"
    done
    echo ""

    echo "  Пакеты dpkg:"
    echo "  ─────────────────────────────────────────────"
    dpkg -l 2>/dev/null | grep 1c-enterprise | awk '{printf "    %-50s %s\n", $2, $3}' || echo "    (не установлены)"
    echo ""
}

do_list_all_repos() {
    instance_list
    if [[ ${#INSTANCES[@]} -eq 0 ]]; then
        echo "  (инстансов нет)"
        return
    fi
    local ip_addr
    ip_addr=$(get_primary_ip)
    local n
    for n in "${INSTANCES[@]}"; do
        instance_load "$n" || continue
        echo ""
        echo "  Инстанс ${n}  (port ${INST_PORT}, ${INST_REPO_DIR})"
        echo "  ─────────────────────────────────────────────"
        if [[ ! -d "$INST_REPO_DIR" ]]; then
            echo "    (каталог не существует)"
            continue
        fi
        local found=0 dir name size
        for dir in "$INST_REPO_DIR"/*/; do
            if [[ -d "$dir" ]]; then
                found=1
                name=$(basename "$dir")
                size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
                echo "    ${name}  [${size:-?}]"
                echo "      → tcp://${ip_addr}:${INST_PORT}/${name}"
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "    (пусто)"
        fi
    done
    echo ""
}

# Диагностика конкретного инстанса. Контекст должен быть загружен (INST_*).
do_diagnose() {
    if [[ -z "${INST_NAME:-}" ]]; then
        log_error "do_diagnose: не задан контекст инстанса"
        return 1
    fi
    local unit="crserver@${INST_NAME}.service"
    local issues=0

    echo "  Диагностика инстанса '${INST_NAME}'"
    echo "  ─────────────────────────────────────────────"

    detect_1c_user
    get_installed_versions

    local bin="/opt/1cv8/x86_64/${INST_VERSION}/crserver"
    if [[ -f "$bin" ]]; then
        log_info "crserver: ${bin}"
    else
        log_error "crserver не найден: ${bin} (фантомная версия)"
        issues=$((issues + 1))
    fi

    if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
        log_info "Установлено версий: ${#INSTALLED_VERSIONS[@]} (${INSTALLED_VERSIONS[*]})"
    else
        log_error "Нет установленных версий"
        issues=$((issues + 1))
    fi

    if [[ -f "$SERVICE_TEMPLATE_FILE" ]]; then
        log_info "Template ${SERVICE_TEMPLATE_FILE} существует"
    else
        log_error "Нет template ${SERVICE_TEMPLATE_FILE}"
        issues=$((issues + 1))
    fi

    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        log_info "Юнит ${unit}: работает"
    else
        log_error "Юнит ${unit}: не работает"
        issues=$((issues + 1))
    fi

    if ss -tlnH 2>/dev/null | awk -v p=":${INST_PORT}" '$4 ~ p"$" {found=1} END {exit !found}'; then
        log_info "Порт ${INST_PORT} слушается"
    else
        log_error "Порт ${INST_PORT} не слушается"
        issues=$((issues + 1))
    fi

    if [[ -d "$INST_REPO_DIR" ]]; then
        local owner
        owner=$(stat -c '%U:%G' "$INST_REPO_DIR" 2>/dev/null || echo "?")
        if [[ "$owner" == "${SVC_USER}:${SVC_GROUP}" ]]; then
            log_info "Права на хранилища: ${owner}"
        else
            log_error "Права на хранилища: ${owner} (ожидается ${SVC_USER}:${SVC_GROUP})"
            issues=$((issues + 1))
        fi
    else
        log_error "Каталог хранилищ ${INST_REPO_DIR} не существует"
        issues=$((issues + 1))
    fi

    if [[ -d "$PACKAGES_DIR" ]]; then
        get_available_versions
        log_info "Каталог пакетов: ${PACKAGES_DIR} (${#AVAILABLE_VERSIONS[@]} версий)"
    else
        log_warn "Каталог пакетов не создан: ${PACKAGES_DIR}"
    fi

    if locale -a 2>/dev/null | grep -q "ru_RU.utf8"; then
        log_info "Локаль ru_RU.UTF-8"
    else
        log_warn "Локаль ru_RU.UTF-8 не найдена"
        issues=$((issues + 1))
    fi

    local disk_usage
    disk_usage=$(df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%' || true)
    if [[ "$disk_usage" =~ ^[0-9]+$ ]]; then
        if [[ $disk_usage -lt 90 ]]; then
            log_info "Диск: ${disk_usage}%"
        else
            log_warn "Диск: ${disk_usage}% — мало места!"
            issues=$((issues + 1))
        fi
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
#  УСТАНОВКА В PATH
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

extract_version() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    awk -F'"' '/^SCRIPT_VERSION=/ {print $2; exit}' "$file"
}

# Возвращает: 0 — равны, 1 — A > B, 2 — A < B
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
        ai="${ai%%[!0-9]*}"; bi="${bi%%[!0-9]*}"
        ai="${ai:-0}"; bi="${bi:-0}"
        if (( 10#$ai > 10#$bi )); then return 1; fi
        if (( 10#$ai < 10#$bi )); then return 2; fi
    done
    return 0
}

# Кэш-бастер на raw.githubusercontent.com (Fastly TTL 5 минут).
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

# Коды возврата do_self_update_check:
#   0   — есть обновление (или удалённая новее)
#   1   — сетевая/парсинговая ошибка (cron должен зафейлиться)
#   100 — установлена актуальная версия (для cron — это успех, не ошибка)
#   101 — локальная версия новее удалённой (тоже не ошибка)
do_self_update_check() {
    log_step "Проверка обновлений..."
    echo "  Источник: ${UPDATE_URL}"
    local tmp
    tmp=$(download_remote_script) || return 1

    local remote_ver
    remote_ver=$(extract_version "$tmp" || true)
    rm -f "$tmp"

    if [[ -z "$remote_ver" ]]; then
        log_error "Не удалось определить версию в удалённом скрипте"
        return 1
    fi

    echo "  Текущая версия:  ${SCRIPT_VERSION}"
    echo "  В репозитории:   ${remote_ver}"

    local cmp
    set +e
    version_compare "$remote_ver" "$SCRIPT_VERSION"; cmp=$?
    set -e

    case $cmp in
        0) log_info "Установлена актуальная версия"; return 100 ;;
        1) log_info "Доступно обновление"; return 0 ;;
        2) log_warn "Локальная версия новее, чем в репозитории"; return 101 ;;
    esac
}

do_self_update() {
    local force="${1:-}"

    # Через симлинк обновляем РЕАЛЬНЫЙ файл, а не симлинк.
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

    local backup_path="${script_path}.bak.$(date +%Y%m%d_%H%M%S)"
    if ! cp -p "$script_path" "$backup_path"; then
        log_error "Не удалось создать резервную копию"
        rm -f "$tmp"
        return 1
    fi
    log_info "Резервная копия: ${backup_path}"

    local mode
    mode=$(stat -c '%a' "$script_path" 2>/dev/null || echo "755")

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
    echo "  3) Обновить принудительно (--force)"
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
    echo "  Использование (общие команды работают с инстансом по умолчанию):"
    echo "    sudo ./crserver-manager.sh                         интерактивное меню"
    echo "    sudo ./crserver-manager.sh install                 первичная установка"
    echo "    sudo ./crserver-manager.sh uninstall               полное удаление"
    echo "    sudo ./crserver-manager.sh start|stop|restart      управление службой"
    echo "    sudo ./crserver-manager.sh status                  статус"
    echo "    sudo ./crserver-manager.sh logs                    логи (последние 50)"
    echo "    sudo ./crserver-manager.sh backup                  создать бэкап"
    echo "    sudo ./crserver-manager.sh diagnose                диагностика"
    echo "    sudo ./crserver-manager.sh healthcheck             одностроковый OK/FAIL для мониторинга"
    echo "    sudo ./crserver-manager.sh versions                список платформ"
    echo "    sudo ./crserver-manager.sh path-install/path-remove"
    echo ""
    echo "  Выбор инстанса:"
    echo "    sudo ./crserver-manager.sh -i <имя> <команда>      на конкретном инстансе"
    echo ""
    echo "  Управление инстансами:"
    echo "    sudo ./crserver-manager.sh instance list"
    echo "    sudo ./crserver-manager.sh instance create <имя> [--version V] [--port P]"
    echo "                                                  [--repo-dir D] [--log-dir L]"
    echo "    sudo ./crserver-manager.sh instance delete <имя> [--purge-data]"
    echo "    sudo ./crserver-manager.sh instance set-default <имя>"
    echo "    sudo ./crserver-manager.sh instance start|stop|restart|status|logs <имя>"
    echo ""
    echo "  Хранилища (берут REPO_DIR из текущего/выбранного инстанса):"
    echo "    sudo ./crserver-manager.sh repo list"
    echo "    sudo ./crserver-manager.sh repo info <имя>"
    echo "    sudo ./crserver-manager.sh repo create <имя>"
    echo "    sudo ./crserver-manager.sh repo delete <имя>"
    echo "    sudo ./crserver-manager.sh repo rename <старое> <новое>"
    echo "    sudo ./crserver-manager.sh repo backup <имя>"
    echo "    sudo ./crserver-manager.sh repo restore <архив.tar.gz | имя_хранилища>"
    echo ""
    echo "  Обновление:"
    echo "    sudo ./crserver-manager.sh update [--check|--force]"
    echo ""
    echo "  Структура каталогов:"
    echo "    ${INSTANCES_DIR}/<имя>.conf"
    echo "    ${SERVICE_TEMPLATE_FILE}"
    echo "    /var/1c/repo-<имя>/   /var/log/1c/<имя>/"
    echo "    ${BACKUP_DIR}/<имя>_<ts>.tar.gz"
    echo "    ${PACKAGES_DIR}/<версия>/*.deb"
    echo ""
    echo "  Подключение из конфигуратора 1С:"
    echo "    Адрес: tcp://IP_СЕРВЕРА:ПОРТ/имя_хранилища"
    echo ""
    if [[ -t 0 && "${HELP_INTERACTIVE:-0}" -eq 1 ]]; then
        read -rp "  Нажмите Enter..." _
    fi
}

# ============================================================================
#  ГЛАВНОЕ МЕНЮ
# ============================================================================

main_menu() {
    while true; do
        instance_list
        get_installed_versions
        local def
        def=$(instance_default)

        clear 2>/dev/null || true
        echo ""
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  Сервер хранилища 1С:Предприятие${NC}   ${CYAN}v${SCRIPT_VERSION}${NC}"

        if [[ ${#INSTANCES[@]} -eq 0 ]]; then
            if [[ -f "$LEGACY_SERVICE_FILE" ]]; then
                echo -e "  ${YELLOW}Обнаружена старая установка v1.x — миграция в меню «Инстансы»${NC}"
            else
                echo -e "  ${YELLOW}Инстансы не настроены — выполните установку (1 → 'install')${NC}"
            fi
        else
            echo -n "  Инстансы: "
            local n status_text status_color first=1
            for n in "${INSTANCES[@]}"; do
                [[ $first -eq 0 ]] && echo -n "  "
                status_text=$(instance_status "$n")
                case "$status_text" in
                    running) status_color="${GREEN}" ;;
                    failed|phantom) status_color="${RED}" ;;
                    *)       status_color="${YELLOW}" ;;
                esac
                local mark=""
                [[ "$n" == "$def" ]] && mark="*"
                echo -ne "${n}${mark} [${status_color}${status_text}${NC}]"
                first=0
            done
            echo ""
            if [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]]; then
                echo "  Платформы: ${INSTALLED_VERSIONS[*]}"
            fi
        fi
        echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
        echo ""
        echo "  1) Управление версиями (1С платформы)"
        echo "  2) Инстансы"
        echo "  3) Управление службами"
        echo "  4) Хранилища конфигураций"
        echo "  5) Файрвол"
        echo "  6) Бэкап и восстановление"
        echo "  7) Инструменты"
        echo "  8) Быстрый вызов (PATH)"
        echo "  9) Обновление скрипта"
        echo " 10) Справка"
        if [[ ${#INSTANCES[@]} -eq 0 ]]; then
            echo ""
            echo " 99) Полная установка (первый раз)"
        fi
        echo ""
        echo "  0) Выход"
        echo ""
        read -rp "  Выберите: " choice

        case $choice in
            1)  do_version_menu ;;
            2)  do_instance_menu ;;
            3)  do_service_menu ;;
            4)  do_repo_menu ;;
            5)  do_access_menu ;;
            6)  do_backup_menu ;;
            7)  do_tools_menu ;;
            8)  do_path_menu ;;
            9)  do_update_menu ;;
            10) HELP_INTERACTIVE=1 do_help ;;
            99) do_full_install ;;
            0)  echo ""; exit 0 ;;
            *)  log_warn "Неверный выбор" ;;
        esac
    done
}

# ============================================================================
#  CLI: парсинг -i и команд
# ============================================================================

# instance подкоманды
cli_instance() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        ""|list)
            local _format="text"
            if [[ "${1:-}" == "--json" ]]; then
                _format="json"
                shift
            fi
            instance_list
            local def n status_text mark ver port repo logd
            def=$(instance_default)
            if [[ "$_format" == "json" ]]; then
                # Без зависимости от jq: собираем JSON вручную с экранированием.
                # Имя инстанса валидировано, версия валидирована, порт — число,
                # пути могут содержать кавычки/слэши, поэтому экранируем явно.
                local _first=1 _esc_repo _esc_logd
                printf '['
                for n in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
                    status_text=$(instance_status "$n")
                    ver=$(awk -F'"' '/^VERSION=/   {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
                    port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
                    repo=$(awk -F'"' '/^REPO_DIR=/  {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
                    logd=$(awk -F'"' '/^LOG_DIR=/   {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
                    _esc_repo=${repo//\\/\\\\}; _esc_repo=${_esc_repo//\"/\\\"}
                    _esc_logd=${logd//\\/\\\\}; _esc_logd=${_esc_logd//\"/\\\"}
                    [[ $_first -eq 0 ]] && printf ','
                    _first=0
                    printf '{"name":"%s","status":"%s","version":"%s","port":%s,"repo_dir":"%s","log_dir":"%s","is_default":%s}' \
                        "$n" "$status_text" "${ver:-}" "${port:-0}" "$_esc_repo" "$_esc_logd" \
                        "$([[ "$n" == "$def" ]] && echo true || echo false)"
                done
                printf ']\n'
                return 0
            fi
            if [[ ${#INSTANCES[@]} -eq 0 ]]; then
                echo "(инстансов нет)"
                return 0
            fi
            printf "%-20s %-10s %-12s %-6s  %s\n" "NAME" "STATUS" "VERSION" "PORT" "REPO_DIR"
            for n in "${INSTANCES[@]}"; do
                status_text=$(instance_status "$n")
                ver=$(awk -F'"' '/^VERSION=/   {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
                port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)
                mark=""
                [[ "$n" == "$def" ]] && mark=" (default)"
                printf "%-20s %-10s %-12s %-6s  %s%s\n" "$n" "$status_text" "${ver:-?}" "${port:-?}" \
                    "$(awk -F'"' '/^REPO_DIR=/ {print $2; exit}' "${INSTANCES_DIR}/${n}.conf" 2>/dev/null || true)" "$mark"
            done
            ;;
        create)
            local name="${1:-}"
            shift || true
            if [[ -z "$name" ]]; then
                log_error "Использование: $0 instance create <имя> [--version V --port P --repo-dir D --log-dir L]"
                return 1
            fi
            if ! instance_name_valid "$name"; then
                log_error "Недопустимое имя"
                return 1
            fi
            if instance_exists "$name"; then
                log_error "Инстанс уже существует: ${name}"
                return 1
            fi
            local ver="" port="" repo="" logd=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version)  ver="${2:-}";  shift 2 ;;
                    --port)     port="${2:-}"; shift 2 ;;
                    --repo-dir) repo="${2:-}"; shift 2 ;;
                    --log-dir)  logd="${2:-}"; shift 2 ;;
                    *) log_error "Неизвестный аргумент: $1"; return 1 ;;
                esac
            done
            # Версия: либо передана, либо есть единственная установленная.
            if [[ -z "$ver" ]]; then
                get_installed_versions
                if [[ ${#INSTALLED_VERSIONS[@]} -ne 1 ]]; then
                    log_error "--version обязателен (установлено версий: ${#INSTALLED_VERSIONS[@]})"
                    return 1
                fi
                ver="${INSTALLED_VERSIONS[0]}"
            fi
            if ! version_name_valid "$ver"; then
                log_error "Некорректная версия: '${ver}' (ожидается 8.3.NN.NNNN)"
                return 1
            fi
            get_installed_versions
            local _v _ver_ok=0
            for _v in "${INSTALLED_VERSIONS[@]+"${INSTALLED_VERSIONS[@]}"}"; do
                [[ "$_v" == "$ver" ]] && _ver_ok=1
            done
            if (( _ver_ok == 0 )); then
                log_error "Версия ${ver} не установлена. Доступные: ${INSTALLED_VERSIONS[*]:-(нет)}"
                return 1
            fi

            # Порт
            port="${port:-$DEFAULT_REPO_PORT}"
            if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                log_error "Некорректный порт: '${port}'"
                return 1
            fi
            # Коллизия с другими инстансами
            local _n _existing_port
            instance_list
            for _n in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
                _existing_port=$(awk -F'"' '/^REPO_PORT=/ {print $2; exit}' "${INSTANCES_DIR}/${_n}.conf" 2>/dev/null || true)
                if [[ "$_existing_port" == "$port" ]]; then
                    log_error "Порт ${port} уже используется инстансом ${_n}"
                    return 1
                fi
            done

            # Пути: только абсолютные, без переноса строк
            repo="${repo:-${REPO_BASE}/repo-${name}}"
            logd="${logd:-${LOG_BASE}/${name}}"
            local _p
            for _p in "$repo" "$logd"; do
                if [[ -z "$_p" || "$_p" != /* || "$_p" == *$'\n'* ]]; then
                    log_error "Некорректный путь: '${_p}' (нужен абсолютный путь без переносов)"
                    return 1
                fi
            done

            INST_VERSION="$ver"
            INST_PORT="$port"
            INST_REPO_DIR="$repo"
            INST_LOG_DIR="$logd"
            if ! instance_save "$name"; then
                return 1
            fi
            detect_1c_user
            mkdir -p "$repo" "$logd" "$BACKUP_DIR"
            if [[ -n "${SVC_USER:-}" && -n "${SVC_GROUP:-}" ]]; then
                chown -R "${SVC_USER}:${SVC_GROUP}" "$repo" "$logd" 2>/dev/null || true
            fi
            generate_systemd_template
            systemctl daemon-reload
            systemctl enable "crserver@${name}.service" >/dev/null 2>&1 || true
            add_input_for_port "$port"
            instance_list
            if [[ ${#INSTANCES[@]} -eq 1 ]]; then
                instance_set_default "$name"
            fi
            log_info "Инстанс ${name} создан"
            ;;
        delete)
            local name="${1:-}"
            shift || true
            local purge=0
            if [[ "${1:-}" == "--purge-data" ]]; then
                purge=1
                shift || true
            fi
            if [[ -z "$name" ]]; then
                log_error "Использование: $0 instance delete <имя> [--purge-data]"
                return 1
            fi
            if ! instance_exists "$name"; then
                log_error "Инстанс не найден: ${name}"
                return 1
            fi
            instance_load "$name" || return 1
            systemctl stop "crserver@${name}.service" 2>/dev/null || true
            systemctl disable "crserver@${name}.service" 2>/dev/null || true
            # cleanup ДО rm -f conf: cleanup_instance_chain читает порт из конфига.
            cleanup_instance_chain "$name"
            remove_input_for_port "$INST_PORT"
            rm -f "${INSTANCES_DIR}/${name}.conf"
            if [[ $purge -eq 1 && -d "$INST_REPO_DIR" ]]; then
                rm -rf "$INST_REPO_DIR" || log_warn "rm -rf не удался"
            fi
            if [[ -f "$DEFAULT_INSTANCE_FILE" ]]; then
                local cur
                cur=$(head -1 "$DEFAULT_INSTANCE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
                [[ "$cur" == "$name" ]] && rm -f "$DEFAULT_INSTANCE_FILE"
            fi
            systemctl daemon-reload
            log_info "Инстанс ${name} удалён"
            ;;
        set-default)
            local name="${1:-}"
            if [[ -z "$name" ]]; then
                log_error "Использование: $0 instance set-default <имя>"
                return 1
            fi
            if instance_set_default "$name"; then
                log_info "По умолчанию: ${name}"
            else
                return 1
            fi
            ;;
        start|stop|restart|status|logs)
            local action="$sub"
            local name="${1:-}"
            if [[ -z "$name" ]]; then
                log_error "Использование: $0 instance ${action} <имя>"
                return 1
            fi
            if ! instance_exists "$name"; then
                log_error "Инстанс не найден: ${name}"
                return 1
            fi
            local unit="crserver@${name}.service"
            case "$action" in
                start)   systemctl start "$unit"   && log_info "Запущен"   || { log_error "Ошибка"; return 1; } ;;
                stop)    systemctl stop "$unit"    && log_info "Остановлен" || { log_error "Ошибка"; return 1; } ;;
                restart) systemctl restart "$unit" && log_info "Перезапущен" || { log_error "Ошибка"; return 1; } ;;
                status)  systemctl status "$unit" --no-pager || true ;;
                logs)    journalctl -u "$unit" -n 50 --no-pager ;;
            esac
            ;;
        *)
            log_error "Использование: $0 instance {list|create|delete|set-default|start|stop|restart|status|logs}"
            return 1
            ;;
    esac
}

# Команды, оперирующие на ВЫБРАННОМ инстансе (CLI_INSTANCE или дефолт)
cli_run_on_instance() {
    local cmd="$1"; shift || true
    cli_select_instance || return 1
    instance_load "$SELECTED_INSTANCE" || return 1
    local unit="crserver@${INST_NAME}.service"
    case "$cmd" in
        start)
            systemctl start "$unit" && log_info "Запущен (${INST_NAME})" || { log_error "Ошибка запуска"; return 1; }
            ;;
        stop)
            systemctl stop "$unit" && log_info "Остановлен (${INST_NAME})" || { log_error "Ошибка остановки"; return 1; }
            ;;
        restart)
            systemctl restart "$unit" && log_info "Перезапущен (${INST_NAME})" || { log_error "Ошибка"; return 1; }
            ;;
        status)
            systemctl status "$unit" --no-pager || true
            ss -tlnpH 2>/dev/null | awk -v p=":${INST_PORT}" '$4 ~ p"$"' || true
            ;;
        logs)
            journalctl -u "$unit" -n 50 --no-pager
            ;;
        backup)
            do_backup
            ;;
        diagnose)
            do_diagnose
            ;;
        healthcheck)
            # Минималистичная проверка для мониторинга/systemd ExecStartPost.
            # exit 0 — служба активна И порт слушается. Иначе exit 1.
            # Без декорирования (NO_COLOR не нужен — выводим в одну строку).
            local _u="crserver@${INST_NAME}.service"
            if ! systemctl is-active --quiet "$_u" 2>/dev/null; then
                echo "FAIL ${INST_NAME}: service not active"
                return 1
            fi
            if ! ss -tlnH 2>/dev/null | awk -v p=":${INST_PORT}" '$4 ~ p"$" {found=1} END {exit !found}'; then
                echo "FAIL ${INST_NAME}: port ${INST_PORT} not listening"
                return 1
            fi
            echo "OK ${INST_NAME}: active on :${INST_PORT}"
            return 0
            ;;
        repo)
            local subcmd="${1:-list}"
            shift || true
            case "$subcmd" in
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
                    if [[ -z "${1:-}" ]]; then
                        log_error "Использование: $0 [-i name] repo create <имя>"
                        return 1
                    fi
                    if ! validate_repo_name "$1"; then
                        log_error "Недопустимое имя"
                        return 1
                    fi
                    detect_1c_user
                    if [[ -z "${SVC_USER:-}" || -z "${SVC_GROUP:-}" ]]; then
                        log_error "Не определён пользователь usr1cv8"
                        return 1
                    fi
                    local d="${INST_REPO_DIR}/$1"
                    if [[ -e "$d" ]]; then
                        log_error "Уже существует: $d"
                        return 1
                    fi
                    mkdir -p "$d"
                    chown "${SVC_USER}:${SVC_GROUP}" "$d"
                    chmod 750 "$d"
                    log_info "Создано: $d"
                    ;;
                delete)
                    if [[ -z "${1:-}" ]]; then
                        log_error "Использование: $0 [-i name] repo delete <имя>"
                        return 1
                    fi
                    if ! validate_repo_name "$1"; then
                        log_error "Недопустимое имя"
                        return 1
                    fi
                    local d="${INST_REPO_DIR}/$1"
                    if [[ ! -d "$d" ]]; then
                        log_error "Не найдено: $d"
                        return 1
                    fi
                    local was_active=0 rm_rc=0
                    if systemctl is-active --quiet "$unit" 2>/dev/null; then
                        was_active=1
                        systemctl stop "$unit" 2>/dev/null || true
                        sleep 1
                    fi
                    rm -rf "$d" || rm_rc=$?
                    if [[ $was_active -eq 1 ]]; then
                        systemctl start "$unit" 2>/dev/null || \
                            log_warn "Служба не стартовала — journalctl -u ${unit}"
                    fi
                    if [[ $rm_rc -ne 0 ]]; then
                        log_error "rm -rf завершился с ошибкой (код ${rm_rc})"
                        return 1
                    fi
                    log_info "Удалено: $1"
                    ;;
                backup)
                    if [[ -z "${1:-}" ]]; then
                        log_error "Использование: $0 [-i name] repo backup <имя>"
                        return 1
                    fi
                    if ! validate_repo_name "$1"; then
                        log_error "Недопустимое имя"
                        return 1
                    fi
                    local d="${INST_REPO_DIR}/$1"
                    if [[ ! -d "$d" ]]; then
                        log_error "Не найдено: $d"
                        return 1
                    fi
                    mkdir -p "$BACKUP_DIR"
                    local ts a
                    ts=$(date +%Y%m%d_%H%M%S)
                    a="${BACKUP_DIR}/${INST_NAME}_repo_${1}_${ts}.tar.gz"
                    trap 'rm -f "$a"; trap - INT TERM; exit 130' INT TERM
                    if ! tar -czf "$a" -C "$INST_REPO_DIR" "$1" 2>/dev/null; then
                        log_error "tar не удался"
                        rm -f "$a"
                        trap - INT TERM
                        return 1
                    fi
                    if ! tar -tzf "$a" >/dev/null 2>&1; then
                        log_error "Архив повреждён (verify не прошёл)"
                        rm -f "$a"
                        trap - INT TERM
                        return 1
                    fi
                    trap - INT TERM
                    log_info "Бэкап: $a"
                    ;;
                rename)
                    if [[ -z "${1:-}" || -z "${2:-}" ]]; then
                        log_error "Использование: $0 [-i name] repo rename <старое> <новое>"
                        return 1
                    fi
                    if ! validate_repo_name "$1" || ! validate_repo_name "$2"; then
                        log_error "Недопустимое имя"
                        return 1
                    fi
                    local old_dir="${INST_REPO_DIR}/$1"
                    local new_dir="${INST_REPO_DIR}/$2"
                    if [[ ! -d "$old_dir" ]]; then
                        log_error "Не найдено: $old_dir"
                        return 1
                    fi
                    if [[ -e "$new_dir" ]]; then
                        log_error "Уже существует: $new_dir"
                        return 1
                    fi
                    local was_active=0
                    if systemctl is-active --quiet "$unit" 2>/dev/null; then
                        was_active=1
                        systemctl stop "$unit" 2>/dev/null || true
                        sleep 1
                    fi
                    if ! mv "$old_dir" "$new_dir"; then
                        log_error "mv не удался"
                        if [[ $was_active -eq 1 ]]; then
                            systemctl start "$unit" 2>/dev/null || true
                        fi
                        return 1
                    fi
                    if [[ $was_active -eq 1 ]]; then
                        systemctl start "$unit" 2>/dev/null || \
                            log_warn "Служба не стартовала — journalctl -u ${unit}"
                    fi
                    log_info "Переименовано: $1 → $2"
                    ;;
                info)
                    if [[ -z "${1:-}" ]]; then
                        log_error "Использование: $0 [-i name] repo info <имя>"
                        return 1
                    fi
                    if ! validate_repo_name "$1"; then
                        log_error "Недопустимое имя"
                        return 1
                    fi
                    local d="${INST_REPO_DIR}/$1"
                    if [[ ! -d "$d" ]]; then
                        log_error "Не найдено: $d"
                        return 1
                    fi
                    local ip_addr
                    ip_addr=$(get_primary_ip)
                    echo "name:    $1"
                    echo "path:    $d"
                    echo "url:     tcp://${ip_addr}:${INST_PORT}/$1"
                    echo "size:    $(du -sh "$d" 2>/dev/null | awk '{print $1}')"
                    echo "files:   $(find "$d" -type f 2>/dev/null | wc -l)"
                    echo "owner:   $(stat -c '%U:%G' "$d" 2>/dev/null)"
                    echo "mode:    $(stat -c '%a' "$d" 2>/dev/null)"
                    echo "mtime:   $(stat -c '%y' "$d" 2>/dev/null | cut -d. -f1)"
                    if repo_looks_initialized "$d"; then
                        echo "status:  initialized"
                    else
                        echo "status:  empty"
                    fi
                    ;;
                restore)
                    # Использование: repo restore <архив|имя_файла>
                    # Если передано полное имя файла — берём как есть. Иначе ищем в BACKUP_DIR
                    # последний бэкап для этого имени хранилища у текущего инстанса.
                    if [[ -z "${1:-}" ]]; then
                        log_error "Использование: $0 [-i name] repo restore <архив.tar.gz | имя_хранилища>"
                        return 1
                    fi
                    local archive=""
                    if [[ -f "$1" ]]; then
                        archive="$1"
                    else
                        if ! validate_repo_name "$1"; then
                            log_error "Недопустимое имя или файл не найден: $1"
                            return 1
                        fi
                        # Берём свежайший бэкап
                        archive=$(find "$BACKUP_DIR" -maxdepth 1 \
                            -name "${INST_NAME}_repo_${1}_*.tar.gz" -printf '%T@ %p\n' 2>/dev/null \
                            | sort -nr | head -1 | cut -d' ' -f2-)
                        if [[ -z "$archive" ]]; then
                            log_error "Бэкапы для '${1}' не найдены в ${BACKUP_DIR}"
                            return 1
                        fi
                    fi

                    # Валидируем содержимое архива
                    local top_dirs name
                    top_dirs=$(tar -tzf "$archive" 2>/dev/null | awk -F/ 'NF>0 && $1!="" {print $1}' | sort -u)
                    if [[ -z "$top_dirs" || $(printf '%s\n' "$top_dirs" | wc -l) -ne 1 ]]; then
                        log_error "Архив пуст или содержит несколько top-level каталогов"
                        return 1
                    fi
                    name="$top_dirs"
                    if ! validate_repo_name "$name"; then
                        log_error "Имя в архиве не похоже на имя хранилища: '${name}'"
                        return 1
                    fi

                    local target="${INST_REPO_DIR}/${name}"
                    local was_active=0
                    if systemctl is-active --quiet "$unit" 2>/dev/null; then
                        was_active=1
                        systemctl stop "$unit" 2>/dev/null || true
                        sleep 1
                    fi
                    local rollback_dir=""
                    if [[ -e "$target" ]]; then
                        rollback_dir="${target}.pre-restore.$(date +%s)"
                        mv "$target" "$rollback_dir"
                    fi
                    if ! tar -xzf "$archive" -C "$INST_REPO_DIR" 2>/dev/null; then
                        log_error "Ошибка распаковки"
                        rm -rf "$target" 2>/dev/null || true
                        [[ -n "$rollback_dir" ]] && mv "$rollback_dir" "$target"
                        if [[ $was_active -eq 1 ]]; then
                            systemctl start "$unit" 2>/dev/null || true
                        fi
                        return 1
                    fi
                    detect_1c_user
                    if [[ -n "${SVC_USER:-}" && -n "${SVC_GROUP:-}" ]]; then
                        chown -R "${SVC_USER}:${SVC_GROUP}" "$target" 2>/dev/null || true
                    fi
                    if [[ $was_active -eq 1 ]]; then
                        systemctl start "$unit" 2>/dev/null || \
                            log_warn "Служба не стартовала — journalctl -u ${unit}"
                    fi
                    log_info "Восстановлено: ${name} (из $(basename "$archive"))"
                    [[ -n "$rollback_dir" ]] && echo "  Прежний вариант: ${rollback_dir}"
                    ;;
                *)
                    log_error "Использование: $0 [-i name] repo {list|info <имя>|create <имя>|delete <имя>|rename <ст> <нв>|backup <имя>|restore <архив|имя>}"
                    return 1
                    ;;
            esac
            ;;
        *)
            log_error "Неизвестная команда: $cmd"
            return 1
            ;;
    esac
}

# ============================================================================
#  ТОЧКА ВХОДА
# ============================================================================

check_root

# Парсим необязательный -i <name>
CLI_INSTANCE=""
# -i/--instance может стоять в любой позиции аргументов (раньше только в
# начале). Например: `crserver start -i dev30` теперь равнозначно
# `crserver -i dev30 start`. Позиционные аргументы сохраняют порядок.
__args=()
__i=0
while (( $# > 0 )); do
    case "$1" in
        -i|--instance)
            if [[ -z "${2:-}" ]]; then
                log_error "Опция $1 требует имя инстанса"
                exit 1
            fi
            CLI_INSTANCE="$2"
            shift 2
            ;;
        --)
            shift
            while (( $# > 0 )); do __args+=("$1"); shift; done
            ;;
        *)
            __args+=("$1")
            shift
            ;;
    esac
done
set -- "${__args[@]+"${__args[@]}"}"
unset __args __i

case "${1:-}" in
    install)       do_full_install ;;
    uninstall)     do_full_uninstall ;;
    start|stop|restart|status|logs|backup|diagnose|healthcheck)
        cli_run_on_instance "$1"
        ;;
    repo|repos)
        shift
        cli_run_on_instance repo "$@"
        ;;
    instance|instances)
        shift
        cli_instance "$@"
        ;;
    versions)
        get_installed_versions
        get_available_versions
        echo ""
        echo -n "  Установленные: "
        [[ ${#INSTALLED_VERSIONS[@]} -gt 0 ]] && echo "${INSTALLED_VERSIONS[*]}" || echo "(нет)"
        echo -n "  Пакеты:        "
        [[ ${#AVAILABLE_VERSIONS[@]} -gt 0 ]] && echo "${AVAILABLE_VERSIONS[*]}" || echo "(нет)"
        echo ""
        ;;
    path-install)  do_path_install ;;
    path-remove)   do_path_uninstall ;;
    update)
        case "${2:-}" in
            ""|--yes|-y) do_self_update ;;
            --check)
                # Преобразуем "семантические" exit-коды:
                #   0   — есть обновление    -> exit 0
                #   100 — актуальная версия  -> exit 0 (для cron — успех)
                #   101 — локальная новее    -> exit 0
                #   1   — ошибка проверки    -> exit 1
                set +e
                do_self_update_check
                __rc=$?
                set -e
                case $__rc in
                    0|100|101) exit 0 ;;
                    *)         exit 1 ;;
                esac
                ;;
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
