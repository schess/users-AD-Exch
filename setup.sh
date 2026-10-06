#!/usr/bin/env bash
# ============================================================================
#  setup.sh — подготовка виртуальной машины к развёртыванию AD-Ruby
#  и развёртывание упакованного приложения (adruby-app-*.tar.gz).
#
#  Целевая ОС: Debian / Ubuntu / Astra Linux SE и другие Debian-подобные
#  системы. Требуются права root (sudo).
#
#  Что делает скрипт:
#    1. Проверяет права root и наличие архива приложения.
#    2. Устанавливает/обновляет окружение: пакеты, Ruby, gems, bundler,
#       Rails-зависимости, Apache 2 и Phusion Passenger (apt, при отсутствии —
#       через gem passenger-install-apache2-module).
#    3. Интерактивно запрашивает всю инфраструктурную информацию:
#       AD (адрес, порт, baseDN, OU уволенных, домен, пароль по умолчанию),
#       Exchange (сервер, IP, БД ящиков, primary/secondary домены) и перечень
#       OU-исключений (можно добавить несколько).
#    4. Генерирует ЕДИНЫЙ конфиг config/infrastructure.yml и синхронизирует
#       его копию для скрипта Exchange (scripts_for_exchange/infrastructure.yml).
#    5. Распаковывает архив приложения в /var/www/adruby.
#    6. Устанавливает gem'ы (bundle install), собирает assets.
#    7. Генерирует секретный ключ приложения (/etc/adruby/secret_key).
#    8. Настраивает виртуальный хост Apache + Passenger (в т.ч. самоподписанный
#       SSL-сертификат, если сертификат ещё не создан).
#    9. Запускает Apache/Passenger и проверяет, что приложение отвечает.
#
#  Использование:
#      sudo bash setup.sh                      # архив ищется рядом со скриптом
#      sudo bash setup.sh /путь/до/adruby-app-....tar.gz
#
#  Возможные переменные окружения (необязательные, для неинтерактивного
#  запуска / переопределения значений по умолчанию):
#      ADRUBY_APP_DIR          - каталог развёртывания (по умолчанию /var/www/adruby)
#      ADRUBY_SERVER_NAME      - ServerName для Apache (по умолчанию: fqdn хоста)
#      ADRUBY_SERVER_IP        - IP веб-сервера
#      ADRUBY_SKIP_BUILD       - '1' - пропустить установку окружения (только деплой)
#      ADRUBY_SKIP_CONF        - '1' - не переспрашивать инфраструктуру (использовать
#                                      существующий infrastructure.yml)
#      ADRUBY_NONINTERACTIVE   - '1' - не задавать вопросов, брать значения из
#                                      существующего файла / env-переменных / дефолтов
#
#  Для полностью автоматического деплоя на "чистой" машине (без существующего
#  конфига) значения инфраструктуры можно передать переменными окружения:
#      ADRUBY_ORG_NAME, ADRUBY_AD_HOST, ADRUBY_AD_PORT, ADRUBY_AD_BASE,
#      ADRUBY_TERMINATED_OU, ADRUBY_DOMAIN, ADRUBY_DEFAULT_PWD,
#      ADRUBY_EXCHANGE_SERVER, ADRUBY_EXCHANGE_IP, ADRUBY_MAILBOX_DB,
#      ADRUBY_PRIMARY_DOMAIN, ADRUBY_SECONDARY_DOMAIN,
#      ADRUBY_EXCLUDED_OUS     - список OU-исключений через запятую
# ============================================================================
set -euo pipefail

# ============================================================================
#  0. Базовые настройки и утилиты
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${ADRUBY_APP_DIR:-/var/www/adruby}"
APP_USER="${APP_USER:-www-data}"
CONF_ABS="$APP_DIR/config/infrastructure.yml"

export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}

# Цвета для вывода
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
C_YLW='\033[1;33m'; C_CYN='\033[0;36m'; C_BLU='\033[0;34m'

info()  { echo -e "${C_CYN}[INFO]${C_RESET} $*"; }
warn()  { echo -e "${C_YLW}[WARN]${C_RESET} $*"; }
err()   { echo -e "${C_RED}[ERROR]${C_RESET} $*"; }
ok()    { echo -e "${C_GRN}[OK]${C_RESET} $*"; }
step()  { echo; echo -e "${C_BLU}=====> $* ${C_RESET}"; }

die() { err "$*"; exit 1; }

# Проверка root
[[ $EUID -eq 0 ]] || die "Скрипт нужно запускать от root:  sudo bash $0"

# --- Поиск архива приложения -------------------------------------------------
ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" ]]; then
    # Ищем первый подходящий архив рядом со скриптом
    ARCHIVE="$(find "$SCRIPT_DIR" -maxdepth 1 -name 'adruby-app-*.tar.gz' | sort | tail -1 || true)"
fi
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || die "Не найден архив приложения (adruby-app-*.tar.gz). Передайте путь: sudo bash $0 /путь/до/архива.tar.gz"
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"

info "Архив приложения: $ARCHIVE"
info "Каталог развёртывания: $APP_DIR"

# ============================================================================
#  1. Установка окружения (Ruby + gems + Rails + Apache + Passenger)
# ============================================================================
install_environment() {
    step "Установка системных пакетов и окружения (может занять время)..."

    apt-get update -y || warn "apt-get update завершился с ошибкой — продолжаю с установкой пакетов."

    # Базовый набор + зависимости для сборки нативного кода (net-ldap, nokogiri,
    # openssl) и Apache.
    apt-get install -y \
        ruby-full ruby-dev \
        build-essential \
        git curl wget ca-certificates \
        libssl-dev zlib1g-dev libreadline-dev \
        libyaml-dev libxml2-dev libxslt1-dev \
        libldap2-dev libsasl2-dev \
        apache2 apache2-dev \
        libapache2-mod-passenger || true

    info "Версии Ruby/gem:"
    ruby -v || true
    gem -v || true

    step "Установка bundler и Rails-зависимостей"
    gem install bundler --no-document || true

    # Rails предпочитаем ставить из gem (в репозиториях Debian версия устаревшая).
    # Если rails уже установлен — пропускаем долгую установку.
    if ! command -v rails >/dev/null 2>&1; then
        warn "Rails не найден в PATH — ставлю через gem (может занять несколько минут)..."
        gem install rails -v '~> 7.2' --no-document || true
    else
        info "Rails уже установлен: $(rails -v 2>/dev/null || echo n/a)"
    fi

    # --- Passenger -----------------------------------------------------------
    # Вариант 1 (предпочтительный): модуль Passenger из apt.
    PASSENGER_READY=0
    if [[ -f /usr/lib/apache2/modules/mod_passenger.so ]] || \
       [[ -f /usr/lib/apache2/modules/mod_passenger_apt.so ]]; then
        PASSENGER_READY=1
    fi
    # Убеждаемся, что модуль реально подключён (a2enmod passenger)
    if [[ "$PASSENGER_READY" -eq 1 ]]; then
        a2enmod passenger >/dev/null 2>&1 || true
        [[ -e /etc/apache2/mods-enabled/passenger.load ]] && PASSENGER_READY=1
    fi

    # Если модуль Passenger не найден — ставим Phusion Passenger из gem и
    # собираем модуль passenger-install-apache2-module.
    if [[ "$PASSENGER_READY" -eq 0 ]]; then
        info "Модуль Passenger из apt не найден — устанавливаю Phusion Passenger через gem."
        gem install passenger -v '~> 6.0' --no-document || true

        local piaam
        piaam="$(command -v passenger-install-apache2-module || true)"
        if [[ -n "$piaam" ]]; then
            # -a автосогласие, -l язык docs (англ.), --auto-only без интерактива
            if passenger-install-apache2-module --auto --languages ruby --auto-only >/tmp/passenger_install.log 2>&1; then
                PASSENGER_READY=1
                # Подключаем сгенерированные директивы Passenger в Apache.
                # passenger-install-apache2-module --snippet выводит нужные
                # LoadModule / PassengerRoot / PassengerDefaultRuby строки.
                local snippet
                snippet="$(passenger-install-apache2-module --snippet 2>/dev/null || true)"
                if [[ -n "$snippet" ]]; then
                    echo "$snippet" > /etc/apache2/conf-available/passenger.conf
                    a2enconf passenger >/dev/null 2>&1 || true
                    ok "Директивы Passenger добавлены в Apache (passenger.conf)."
                fi
            else
                warn "passenger-install-apache2-module завершился с ошибкой (см. /tmp/passenger_install.log)."
            fi
        else
            warn "Не найден passenger-install-apache2-module. Проверьте установку gem 'passenger'."
        fi
    fi

    if [[ "$PASSENGER_READY" -eq 1 ]]; then
        ok "Passenger модуль доступен."
    else
        warn "Не удалось автоматически подготовить модуль Passenger."
        warn "Проверьте вывод выше. Как минимум должны быть установлены: ruby, ruby-dev, apache2-dev, libapache2-mod-passenger."
        ask_continue "Продолжить без готового модуля Passenger? (деплой будет выполнен, но Apache может не поднять приложение)"
    fi

    # Включаем нужные модули Apache
    a2enmod rewrite headers ssl 2>/dev/null || true
    if [[ "$PASSENGER_READY" -eq 1 ]]; then
        a2enmod passenger 2>/dev/null || true
    fi
}

# ============================================================================
#  Утилиты ввода
# ============================================================================
# prompt <переменная> <сообщение> <дефолт>
#   read-значение кладётся в глобальную переменную
ask() {
    local __var="$1" msg="$2" default="${3:-}" input
    if [[ "${ADRUBY_NONINTERACTIVE:-0}" == "1" ]]; then
        eval "$__var='$default'"
        return
    fi
    if [[ -n "$default" ]]; then
        read -r -p "$(echo -e "  ${C_CYN}${msg}${C_RESET} [${default}]: ")" input
        input="${input:-$default}"
    else
        read -r -p "$(echo -e "  ${C_CYN}${msg}${C_RESET}: ")" input
    fi
    eval "$__var='$input'"
}

ask_continue() {
    local reply
    if [[ "${ADRUBY_NONINTERACTIVE:-0}" == "1" ]]; then return 0; fi
    read -r -p "$(echo -e "  ${C_YLW}$1 [y/N]: ${C_RESET}")" reply
    [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# ============================================================================
#  Чтение существующего infrastructure.yml (для значений по умолчанию)
# ============================================================================
load_existing_conf() {
    local f="$1" sec="" key=""
    [[ -f "$f" ]] || return 0
    # Идемпотентность: сбрасываем список исключений на каждой загрузке,
    # чтобы повторные вызовы не накапливали элементы в глобальном массиве.
    EXCL_OUS=()
    while IFS= read -r line; do
        # Отличаем секцию (без отступа) от вложенных ключей (с отступом),
        # сохраняя начальные пробелы (как это делает PS1-парсер Exchange).
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Секция верхнего уровня: строка БЕЗ отступа вида "ключ:"
        if [[ "$line" =~ ^[a-zA-Z0-9_]+:[[:space:]]*$ ]]; then
            sec="$(echo "$line" | sed -E 's/:.*//')"; key=""; continue
        fi
        # Вложенный ключ: строка С отступом вида "  ключ: значение"
        if [[ "$line" =~ ^[[:space:]]+[a-zA-Z0-9_]+:[[:space:]]*(.*)$ && -n "$sec" ]]; then
            local k v
            k="$(echo "$line" | sed -E 's/^[[:space:]]+([a-zA-Z0-9_]+):.*/\1/')"
            v="$line"; v="${v#*:}"; v="$(echo "$v" | sed -E 's/[[:space:]]*#[^"]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
            key="$k"
            v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
            case "$sec:$k" in
                organization:name)         DEF_ORG_NAME="$v" ;;
                ad:host)                   DEF_AD_HOST="$v" ;;
                ad:port)                   DEF_AD_PORT="$v" ;;
                ad:base)                   DEF_AD_BASE="$v" ;;
                ad:terminated_ou)          DEF_TERMINATED_OU="$v" ;;
                ad:domain)                 DEF_DOMAIN="$v" ;;
                ad:default_password)       DEF_DEFAULT_PWD="$v" ;;
                exchange:server)           DEF_EX_SERVER="$v" ;;
                exchange:ip)               DEF_EX_IP="$v" ;;
                exchange:mailbox_db)       DEF_MAILBOX_DB="$v" ;;
                exchange:primary_domain)   DEF_PRIMARY_DOMAIN="$v" ;;
                exchange:secondary_domain) DEF_SECONDARY_DOMAIN="$v" ;;
            esac
            continue
        fi
        # Элемент списка: "    - \"значение\""
        if [[ "$line" =~ ^[[:space:]]*-\ [\"\']?(.*)[\"\']?[[:space:]]*$ && "$sec" == "exchange" && "$key" == "excluded_ous" ]]; then
            local i="${BASH_REMATCH[1]}"
            i="${i%\"}"; i="${i#\"}"; i="${i%\'}"; i="${i#\'}"
            EXCL_OUS+=("$i")
        fi
    done < "$f"
}

# ============================================================================
#  3. Интерактивный опрос инфраструктуры и генерация infrastructure.yml
# ============================================================================
EXCL_OUS=()
DEF_ORG_NAME=""; DEF_AD_HOST=""; DEF_AD_PORT="636"; DEF_AD_BASE=""
DEF_TERMINATED_OU=""; DEF_DOMAIN=""; DEF_DEFAULT_PWD=""
DEF_EX_SERVER=""; DEF_EX_IP=""; DEF_MAILBOX_DB=""; DEF_PRIMARY_DOMAIN=""; DEF_SECONDARY_DOMAIN=""

collect_infrastructure() {
    # Читаем значения по умолчанию из уже существующего конфига
    load_existing_conf "$CONF_ABS"

    step "Сбор информации об инфраструктуре (введите значения или Enter для значения по умолчанию)"

    echo -e "\n${C_CYN}--- Организация ---${C_RESET}"
    ask ORG_NAME "Название организации (заголовок приложения)" "${DEF_ORG_NAME:-ФГАУ ЦИТ}"

    echo -e "\n${C_CYN}--- Active Directory / домен ---${C_RESET}"
    ask AD_HOST "IP-адрес контроллера домена (AD/LDAPS)" "$DEF_AD_HOST"
    ask AD_PORT "Порт LDAPS (обычно 636)" "${DEF_AD_PORT:-636}"
    ask AD_BASE "baseDN OU, из которой приложение берёт/создаёт пользователей (например OU=Users,DC=corp,DC=local)" "$DEF_AD_BASE"
    ask TERMINATED_OU "Полный DN OU уволенных сотрудников (куда переносить при увольнении)" "$DEF_TERMINATED_OU"
    ask DOMAIN "Домен (NetBIOS/UPN, например corp.local)" "$DEF_DOMAIN"
    ask DEFAULT_PWD "Пароль по умолчанию для новых пользователей (например P@ssw0rd)" "$DEF_DEFAULT_PWD"

    echo -e "\n${C_CYN}--- Microsoft Exchange ---${C_RESET}"
    ask EX_SERVER "Имя сервера Exchange (например EXCHANGE-01)" "$DEF_EX_SERVER"
    ask EX_IP "IP-адрес сервера Exchange" "$DEF_EX_IP"
    ask MAILBOX_DB "База данных почтовых ящиков (например DB01)" "$DEF_MAILBOX_DB"
    ask PRIMARY_DOMAIN "Primary SMTP-домен (например corp.local)" "$DEF_PRIMARY_DOMAIN"
    ask SECONDARY_DOMAIN "Secondary SMTP-домен (можно оставить пустым)" "$DEF_SECONDARY_DOMAIN"

    # --- OU исключений (можно несколько) -------------------------------------
    # Возможна ситуация: у нас уже есть исключения из существующего конфига.
    # Используем их как стартовый список, но позволяем добавить ещё.
    echo -e "\n${C_CYN}--- OU-исключения (для которых почтовые ящики НЕ создаются) ---${C_RESET}"
    echo "  Введите полное имя OU (например 'OU=Уволенные,OU=Users,DC=corp,DC=local'),"
    echo "  по одному. Пустой ввод — закончить добавление."

    while true; do
        # Показываем текущий список
        if [[ ${#EXCL_OUS[@]} -gt 0 ]]; then
            echo -e "  ${C_GRN}Текущие исключения:${C_RESET}"
            for i in "${!EXCL_OUS[@]}"; do
                echo "    $((i+1)). ${EXCL_OUS[$i]}"
            done
        fi

        if [[ "${ADRUBY_NONINTERACTIVE:-0}" == "1" ]]; then break; fi

        read -r -p "  Введите OU исключения (Enter - готово): " ou
        if [[ -z "$ou" ]]; then
            break
        fi
        # Проверка дублей (регистронезависимо)
        local dup=0
        for e in "${EXCL_OUS[@]}"; do
            if [[ "${e,,}" == "${ou,,}" ]]; then dup=1; break; fi
        done
        if [[ "$dup" -eq 1 ]]; then
            warn "Такое OU уже добавлено — пропускаю."
            continue
        fi
        EXCL_OUS+=("$ou")
    done

    if [[ ${#EXCL_OUS[@]} -eq 0 ]]; then
        warn "Список OU-исключений пуст — исключений нет."
    fi
}

# Генерация YAML с сохранением порядка секций, понятного и скрипту Exchange.
write_infrastructure_yml() {
    local out="$1"
    local dir
    dir="$(dirname "$out")"
    mkdir -p "$dir"

    # Юникод-значения (напр. имя организации, OU с кириллицей) пишем как есть —
    # YAML и Rails, и PS1-парсер (чтение UTF-8) корректно их обработают.
    {
        echo "# ============================================================================="
        echo "#  Центральный конфигурационный файл инфраструктуры проекта AD-Ruby."
        echo "#  Сгенерирован автоматически скриптом setup.sh."
        echo "#  Единый источник истины: адреса AD/Exchange, домены, OU-исключения."
        echo "#  ВАЖНО: файл содержит УЧЁТНЫЕ ДАННЫЕ (пароль) — защищайте доступ к нему."
        echo "# ============================================================================="
        echo
        echo "# --- Организация --------------------------------------------------------------"
        echo "organization:"
        echo "  name: \"$ORG_NAME\""
        echo
        echo "# --- Active Directory / домен -----------------------------------------------"
        echo "ad:"
        echo "  host: \"$AD_HOST\""
        echo "  port: $AD_PORT"
        echo "  base: \"$AD_BASE\""
        echo "  terminated_ou: \"$TERMINATED_OU\""
        echo "  domain: \"$DOMAIN\""
        echo "  default_password: \"$DEFAULT_PWD\""
        echo
        echo "# --- Microsoft Exchange ------------------------------------------------------"
        echo "exchange:"
        echo "  server: \"$EX_SERVER\""
        echo "  ip: \"$EX_IP\""
        echo "  mailbox_db: \"$MAILBOX_DB\""
        echo "  primary_domain: \"$PRIMARY_DOMAIN\""
        echo "  secondary_domain: \"$SECONDARY_DOMAIN\""
        echo "  excluded_ous:                             # OU, для которых ящики НЕ создаём"
        if [[ ${#EXCL_OUS[@]} -eq 0 ]]; then
            echo "  # (исключений нет)"
        else
            for _ou in "${EXCL_OUS[@]}"; do
                echo "    - \"$_ou\""
            done
        fi
        echo
        echo "# --- Веб-сервер / прод --------------------------------------------------------"
        echo "server:"
        echo "  name: \"$APP_SERVER_NAME\""
        echo "  ip: \"$APP_SERVER_IP\""
    } > "$out"

    ok "Сгенерирован конфиг: $out"
}

# ============================================================================
#  5. Распаковка приложения
# ============================================================================
deploy_app() {
    step "Развёртывание приложения в $APP_DIR"
    local tmp
    tmp="$(mktemp -d)"

    tar xzf "$ARCHIVE" -C "$tmp"
    # В архиве каталог называется adruby-app (см. package.sh). Находим его.
    local src_root
    src_root="$(find "$tmp" -maxdepth 2 -name Gemfile -printf '%h\n' | head -1)"
    [[ -n "$src_root" ]] || die "В архиве не найден корень Rails-приложения (Gemfile)."

    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR"

    # Копируем код (исключая лишнее)
    mkdir -p "$tmp/_clean"; cp -a "$src_root"/. "$tmp/_clean"/
    rm -rf "$tmp/_clean/log" "$tmp/_clean/tmp" "$tmp/_clean/vendor/bundle" "$tmp/_clean/.bundle" \
           "$tmp/_clean/config/master.key" "$tmp/_clean/config/secrets.yml" \
           "$tmp/_clean/config/credentials.yml.enc"
    cp -a "$tmp/_clean"/. "$APP_DIR/"
    rm -rf "$tmp"

    # Создаём рантайм-каталоги
    mkdir -p "$APP_DIR/tmp/sessions" "$APP_DIR/tmp/cache" "$APP_DIR/tmp/pids" "$APP_DIR/log"

    # Набор прав
    chown -R "root:$APP_USER" "$APP_DIR" 2>/dev/null || true
    chmod -R u+rwX,g+rwX,o+rX "$APP_DIR" 2>/dev/null || true
}

# ============================================================================
#  6. Секретный ключ приложения
# ============================================================================
generate_secret_key() {
    step "Генерация секретного ключа приложения"
    local key_dir="/etc/adruby"
    mkdir -p "$key_dir"
    if [[ ! -s "$key_dir/secret_key" ]]; then
        # Допустимая длина для secret_key_base Rails — не менее 64 hex-символов.
        openssl rand -hex 64 > "$key_dir/secret_key" 2>/dev/null || \
            tr -dc 'a-f0-9' < /dev/urandom | head -c128 > "$key_dir/secret_key"
        chmod 600 "$key_dir/secret_key"
        ok "Создан файл секретного ключа: $key_dir/secret_key"
    else
        info "Секретный ключ уже существует — не трогаю."
    fi
}

# ============================================================================
#  8. Конфигурация Apache + Passenger
# ============================================================================
configure_apache() {
    step "Настройка Apache + Passenger"
    local vhost="/etc/apache2/sites-available/adruby.conf"
    local fqdn="${APP_SERVER_NAME}"

    # --- Самоподписанный SSL-сертификат (если отсутствует) ------------------
    local cert="/etc/ssl/certs/adruby.pem"
    local key="/etc/ssl/private/adruby.key"
    if [[ ! -f "$cert" || ! -f "$key" ]]; then
        info "Генерирую самоподписанный SSL-сертификат для '$fqdn'..."
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "$key" -out "$cert" \
            -subj "/CN=$fqdn/O=AD-Ruby" 2>/dev/null || \
            warn "Не удалось сгенерировать SSL-сертификат (продолжим без HTTPS)."
    fi

    cat > "$vhost" <<EOF
# Apache VirtualHost for AD-Ruby (Phusion Passenger serving Rails)
# Автоматически сгенерирован setup.sh
<VirtualHost *:80>
    ServerName $fqdn
    ServerAdmin admin@${DOMAIN:-localhost}

    # Disable Astra PARSEC MDA authentication for this vhost (fixes AM00001 500)
    AstraMode off

    # Redirect all HTTP to HTTPS
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^(.*)$ https://%{HTTP_HOST}\$1 [R=301,L]

    ErrorLog \${APACHE_LOG_DIR}/adruby_error.log
    CustomLog \${APACHE_LOG_DIR}/adruby_access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName $fqdn
    ServerAdmin admin@${DOMAIN:-localhost}

    # Disable Astra PARSEC MDA authentication for this vhost (fixes AM00001 500)
    AstraMode off

    DocumentRoot $APP_DIR/public

    <Directory $APP_DIR/public>
        Options -MultiViews
        AllowOverride All
        Require all granted
    </Directory>

    PassengerAppEnv production
    PassengerAppRoot $APP_DIR
    PassengerRuby $(command -v ruby || echo /usr/bin/ruby)

    <IfModule mod_ssl.c>
    SSLEngine on
    SSLCertificateFile $cert
    SSLCertificateKeyFile $key
    </IfModule>

    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder off

    ErrorLog \${APACHE_LOG_DIR}/adruby_error.log
    CustomLog \${APACHE_LOG_DIR}/adruby_access.log combined
</VirtualHost>
EOF

    a2dissite 000-default 2>/dev/null || true
    a2ensite adruby 2>/dev/null || true

    if apachectl configtest 2>&1 | grep -qi 'Syntax OK'; then
        ok "Конфигурация Apache корректна."
    else
        warn "Предупреждение: apachectl configtest сообщил о проблемах (см. выше)."
        ask_continue "Продолжить, несмотря на предупреждение Apache?"
    fi
}

# ============================================================================
#  7 (после деплоя). Установка gem'ов и сборка assets
# ============================================================================
build_assets() {
    step "Установка gem'ов (bundle install) и сборка assets"
    if ! command -v bundle >/dev/null 2>&1; then
        gem install bundler --no-document || true
    fi
    cd "$APP_DIR"
    # Устанавливаем зависимости от имени непривилегированного пользователя,
    # чтобы Passenger (работающий от самого пользователя) мог их читать.
    sudo -u "$APP_USER" bash -lc "
        export PATH=\"\$PATH:/usr/local/bin:/usr/bin\"
        cd '$APP_DIR'
        bundle config set --local path 'vendor/bundle' 2>/dev/null || true
        bundle config set --local without 'development test' 2>/dev/null || true
        bundle install 2>&1 || bundle install
        bundle exec rails assets:precompile 2>/dev/null || true
    " || true

    chown -R "root:$APP_USER" "$APP_DIR" 2>/dev/null || true
    chmod -R u+rwX,g+rwX,o+rX "$APP_DIR" 2>/dev/null || true
}

# ============================================================================
#  9. Запуск и проверка
# ============================================================================
start_services() {
    step "Запуск Apache"
    systemctl restart apache2 2>/dev/null || service apache2 restart 2>/dev/null || true
    sleep 3

    # Рестарт приложения Passenger
    if command -v passenger-config >/dev/null 2>&1; then
        passenger-config restart-app --name "$APP_DIR" 2>/dev/null || true
    fi
    touch "$APP_DIR/tmp/restart.txt"

    echo
    ok "Развёртывание завершено."
    echo
    echo -e "  URL приложения: ${C_GRN}https://${APP_SERVER_NAME}${C_RESET}  (или по IP http://${APP_SERVER_IP})"
    echo -e "  Каталог приложения: ${C_CYN}${APP_DIR}${C_RESET}"
    echo -e "  Конфиг инфраструктуры: ${C_CYN}${CONF_ABS}${C_RESET}"
    echo -e "  Секретный ключ: ${C_CYN}/etc/adruby/secret_key${C_RESET}"
    echo

    # Небольшая проверка (HTTP-запрос к корню)
    if command -v curl >/dev/null 2>&1; then
        local code
        code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1/" || true)"
        echo -e "  Проверка HTTP-ответа корня: ${C_CYN}${code:-нет ответа}${C_RESET}"
    fi

    echo
    echo "=== Готово. Приложение развёрнуто и запущено. ==="
}

# ============================================================================
#  MAIN
# ============================================================================
SERVER_NAME="${SERVER_NAME:-}"
FQDN_DEFAULT="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo adruby)"

if [[ "${ADRUBY_SKIP_CONF:-0}" != "1" && "${ADRUBY_NONINTERACTIVE:-0}" != "1" ]]; then
    collect_infrastructure
    step "Имя/адрес сервера (для Apache vhost)"
    ask APP_SERVER_NAME "ServerName (FQDN) веб-сервера" "$FQDN_DEFAULT"
    ask APP_SERVER_IP "IP-адрес веб-сервера" "$(hostname -I 2>/dev/null | awk '{print $1}')"
else
    # Неинтерактивный режим / значения по умолчанию. Порядок приоритета:
    #   переменная окружения ADRUBY_* > существующий config/infrastructure.yml > дефолт.
    load_existing_conf "$CONF_ABS"
    ORG_NAME="${ADRUBY_ORG_NAME:-${DEF_ORG_NAME:-ФГАУ ЦИТ}}"
    AD_HOST="${ADRUBY_AD_HOST:-$DEF_AD_HOST}";  AD_PORT="${ADRUBY_AD_PORT:-${DEF_AD_PORT:-636}}"
    AD_BASE="${ADRUBY_AD_BASE:-$DEF_AD_BASE}"
    TERMINATED_OU="${ADRUBY_TERMINATED_OU:-$DEF_TERMINATED_OU}"
    DOMAIN="${ADRUBY_DOMAIN:-$DEF_DOMAIN}";    DEFAULT_PWD="${ADRUBY_DEFAULT_PWD:-$DEF_DEFAULT_PWD}"
    EX_SERVER="${ADRUBY_EXCHANGE_SERVER:-$DEF_EX_SERVER}"; EX_IP="${ADRUBY_EXCHANGE_IP:-$DEF_EX_IP}"
    MAILBOX_DB="${ADRUBY_MAILBOX_DB:-$DEF_MAILBOX_DB}"
    PRIMARY_DOMAIN="${ADRUBY_PRIMARY_DOMAIN:-$DEF_PRIMARY_DOMAIN}"
    SECONDARY_DOMAIN="${ADRUBY_SECONDARY_DOMAIN:-$DEF_SECONDARY_DOMAIN}"
    APP_SERVER_NAME="${ADRUBY_SERVER_NAME:-$FQDN_DEFAULT}"
    APP_SERVER_IP="${ADRUBY_SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    ADRUBY_SKIP_CONF=1
fi

# Неинтерактивно можно задать OU-исключения через ADRUBY_EXCLUDED_OUS
# (через запятую). Добавляются к уже загруженным из существующего конфига.
if [[ -n "${ADRUBY_EXCLUDED_OUS:-}" ]]; then
    IFS=',' read -ra _env_ous <<< "$ADRUBY_EXCLUDED_OUS"
    for _o in "${_env_ous[@]}"; do
        _o="$(echo "$_o" | sed 's/^[[:space:]]*\|[[:space:]]*$//g')"
        [[ -n "$_o" ]] && EXCL_OUS+=("$_o")
    done
fi

# --- Установка окружения (можно пропустить) -----------------------------------
if [[ "${ADRUBY_SKIP_BUILD:-0}" != "1" ]]; then
    install_environment
fi

deploy_app

# Конфиг инфраструктуры.
#   - Если задан ADRUBY_SKIP_CONF=1 и конфиг уже существует — используем его
#     как есть (не переспрашиваем, не генерируем заново).
#   - Иначе генерируем config/infrastructure.yml на основе собранных значений
#     (интерактивных или значений по умолчанию).
if [[ "${ADRUBY_SKIP_CONF:-0}" == "1" && -f "$CONF_ABS" ]]; then
    info "ADRUBY_SKIP_CONF=1 и конфиг уже существует — оставляю $CONF_ABS как есть."
else
    write_infrastructure_yml "$CONF_ABS"
fi

# Синхронизация копии для скрипта Exchange (scripts_for_exchange/).
# Если ADRUBY_SKIP_CONF=1 и существующего конфига не было — предупреждаем.
EXCH_CONF="$APP_DIR/scripts_for_exchange/infrastructure.yml"
if [[ -d "$APP_DIR/scripts_for_exchange" ]]; then
    cp "$CONF_ABS" "$EXCH_CONF"
    ok "Скопирован конфиг для Exchange: $EXCH_CONF"
fi

generate_secret_key
build_assets
configure_apache
start_services
