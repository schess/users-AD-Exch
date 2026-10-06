#!/usr/bin/env bash
# ============================================================================
#  package.sh — сборка дистрибутива AD-Ruby в tar.gz для переноса на другой
#  сервер.
#
#  Скрипт пакует каталог приложения (по умолчанию ./adruby-app) в архив
#  вида:
#      adruby-app-<ruby>-<rails>-<дата>-<хэш>.tar.gz
#
#  Что входит в архив:
#    - весь код Rails-приложения (app/, config/, bin/, Gemfile, и т.д.);
#    - скрипты для Exchange (scripts_for_exchange/);
#    - шаблон infrastructure.yml (config/infrastructure.yml.tpl), из которого
#      setup.sh на целевом сервере сгенерирует настоящий infrastructure.yml.
#
#  Что НЕ входит в архив (секреты и рантайм, генерируются на сервере):
#    - config/infrastructure.yml        (генерируется setup.sh из промптов);
#    - config/master.key, secrets.yml,
#      credentials.yml.enc              (секреты; вместо них создаётся новый);
#    - log/, tmp/, vendor/bundle/, .bundle/
#    - *.log, *.key
#
#  Использование:
#      bash package.sh                 # упаковать ./adruby-app
#      bash package.sh /путь/к/приложению
#
#  Результат появится в текущем каталоге (или в каталоге -O).
# ============================================================================
set -euo pipefail

# --- 1. Источник (каталог приложения) и каталог вывода -----------------------
SRC="${1:-$(cd "$(dirname "$0")" && pwd)/adruby-app}"
SRC="$(cd "$SRC" && pwd)"

OUT_DIR="${OUT_DIR:-$(pwd)}"
mkdir -p "$OUT_DIR"

if [[ ! -f "$SRC/Gemfile" ]]; then
    echo "ERROR: в каталоге $SRC нет Gemfile — это не каталог Rails-приложения AD-Ruby." >&2
    exit 1
fi

# --- 2. Определяем версии для имени архива -----------------------------------
RUBY_V="$(grep -Eo 'ruby-?[0-9]+\.[0-9]+\.[0-9]+' "$SRC/.ruby-version" 2>/dev/null | head -1 || true)"
RUBY_V="${RUBY_V:-unknown-ruby}"

RAILS_V="$(grep -Eo 'rails.*~> *"?[0-9]+\.[0-9]+(\.[0-9]+)?' "$SRC/Gemfile" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
RAILS_V="${RAILS_V:-unknown-rails}"

STAMP="$(date +%Y%m%d)"
HASH="$(cd "$SRC" && git rev-parse --short HEAD 2>/dev/null || echo 'pkg')"
ARCHIVE_NAME="adruby-app-ruby-${RUBY_V:-ruby}-rails-${RAILS_V}-${STAMP}-${HASH}.tar.gz"
ARCHIVE="$OUT_DIR/$ARCHIVE_NAME"

# --- 3. Упаковка (tar с относительными путями, из каталога приложения) --------
echo "Упаковка приложения из: $SRC"
echo "Архив:                 $ARCHIVE"

# Строим список исключений (секреты и рантайм не должны попасть в архив).
EXCLUDES=(
    --exclude='adruby-app/config/infrastructure.yml'
    --exclude='adruby-app/config/infrastructure.yaml'
    --exclude='.git'
    --exclude='log'
    --exclude='tmp'
    --exclude='vendor/bundle'
    --exclude='.bundle'
    --exclude='*.log'
    --exclude='*.key'
    --exclude='config/master.key'
    --exclude='config/secrets.yml'
    --exclude='config/credentials.yml.enc'
)

# Пакуем каталог, но в архиве хотим иметь путь "adruby-app/...", чтобы setup.sh
# знал, где корень приложения.
(cd "$(dirname "$SRC")" && tar czf "$ARCHIVE" "${EXCLUDES[@]}" "$(basename "$SRC")")

echo
echo "Готово: $ARCHIVE"
ls -lh "$ARCHIVE"
echo
echo "Перенесите этот архив на целевой сервер рядом со скриптом setup.sh"
echo "и выполните:  sudo bash setup.sh $(basename "$ARCHIVE")"
