# AD-Ruby: развёртывание на новом сервере (setup.sh)

Проект подготавливается к **переносу на другой сервер / другую инфраструктуру**
двумя скриптами:

| Скрипт | Где запускается | Назначение |
|---|---|---|
| [`package.sh`](package.sh) | на машине сборки (где есть исходники) | собирает дистрибутив приложения в `tar.gz` |
| [`setup.sh`](setup.sh) | на целевом сервере (Debian-подобном) | готовит окружение и разворачивает приложение |

`setup.sh` **не зависит от GitLab/CI**: он разворачивает именно упакованный
`tar.gz`, поэтому подходит для переноса в изолированную сеть.

---

## 1. Общая схема работы

```
[Машина сборки]                 [Целевой сервер (Debian-like)]
  bash package.sh      ──►  adruby-app-...tar.gz  ──►  sudo bash setup.sh <архив>
  (собирает архив)             файл переносится            (готовая инсталляция)
```

### Шаг 1. Сборка дистрибутива (package.sh)

```bash
bash package.sh                 # упакует ./adruby-app
bash package.sh /путь/к/приложению
```

Будет создан архив вида `adruby-app-ruby-3.1.2-rails-7.2-20261006-<hash>.tar.gz`.

**Что входит в архив:**

- весь код Rails-приложения (`app/`, `config/`, `bin/`, `Gemfile`, …);
- скрипты для Exchange (`scripts_for_exchange/`);
- шаблон конфига `config/infrastructure.yml.tpl` (пример структуры).

**Что намеренно НЕ входит** (генерируется на сервере, т.к. зависит от новой среды
и содержит секреты):

- `config/infrastructure.yml` — настраивается `setup.sh` под новые адреса AD/Exchange;
- `config/master.key`, `config/secrets.yml`, `config/credentials.yml.enc` — вместо
  них `setup.sh` генерирует новый секретный ключ `/etc/adruby/secret_key`;
- `log/`, `tmp/`, `vendor/bundle/`, `.bundle/`, `*.log`, `*.key`.

### Шаг 2. Развёртывание (setup.sh)

```bash
# Скопируйте setup.sh и архив на целевой сервер и запустите:
sudo bash setup.sh                             # архив найдётся рядом со скриптом
sudo bash setup.sh /путь/до/adruby-app-....tar.gz
```

> Скрипт должен выполняться от **root** (через `sudo`). Работает на
> Debian / Ubuntu / Astra Linux SE и других Debian-подобных системах.

---

## 2. Что делает setup.sh (по шагам)

### 2.1. Проверка и входные данные
- Проверяет, что запущен от root.
- Ищет архив: переданный аргументом, либо первый `adruby-app-*.tar.gz` рядом
  со скриптом.

### 2.2. Установка окружения
`apt-get update` + установка пакетов:

- **Ruby** (`ruby-full`) и инструменты сборки (`build-essential`, `libssl-dev`,
  `zlib1g-dev`, `libreadline-dev`, `libyaml-dev`, `libxml2-dev`, `libxslt1-dev`,
  `libldap2-dev`, `libsasl2-dev` — нужны для нативных gem'ов net-ldap/nokogiri);
- **bundler** (`gem install bundler`);
- **Rails** (если не установлен — ставится из gem `rails ~> 7.2`);
- **Apache 2** (`apache2`, `apache2-dev`);
- **Phusion Passenger**:
  1. сначала пробует системный модуль `libapache2-mod-passenger` из apt
     (проверка модуля `mod_passenger[_apt].so` и `passenger.load`);
  2. если модуля нет — ставит gem `passenger ~> 6.0` и собирает модуль
     `passenger-install-apache2-module`, после чего подключает директивы
     Passenger в Apache через `/etc/apache2/conf-available/passenger.conf`;
  3. если модуль подготовить не удалось — предупреждает и предлагает продолжить
     (деплой выполняется, но приложение может не подняться).

Включаются модули Apache: `rewrite`, `headers`, `ssl`, и `passenger` (если готов).

### 2.3. Интерактивный сбор инфраструктуры
Скрипт задаёт вопросы и генерирует **единый конфиг** `config/infrastructure.yml`.

**Организация:**
- `organization.name` — название организации (заголовок приложения).

**Active Directory / домен:**
- `ad.host` — IP-адрес контроллера домена (AD/LDAPS);
- `ad.port` — порт LDAPS (по умолчанию 636);
- `ad.base` — **baseDN** OU, из которой приложение берёт/создаёт пользователей
  (например `OU=Users,DC=corp,DC=local`);
- `ad.terminated_ou` — полный DN OU уволенных сотрудников (куда переносятся
  учётки при увольнении);
- `ad.domain` — домен (NetBIOS/UPN, например `corp.local`);
- `ad.default_password` — пароль по умолчанию для новых пользователей.

**Microsoft Exchange:**
- `exchange.server` — имя сервера Exchange;
- `exchange.ip` — IP-адрес сервера Exchange;
- `exchange.mailbox_db` — база данных почтовых ящиков (например `DB01`);
- `exchange.primary_domain` — primary SMTP-домен;
- `exchange.secondary_domain` — secondary SMTP-домен.

**OU-исключения** (`exchange.excluded_ous`) — **можно добавить несколько**:
скрипт циклически запрашивает полное имя OU (например
`OU=Уволенные,OU=Users,DC=corp,DC=local`), по одному за раз. Пустой ввод —
закончить добавление. Каждое OU попадает в список исключений (для таких учёток
Exchange-скрипт ящики не создаёт). Дубликаты отбрасываются автоматически.

**Веб-сервер (для Apache):**
- `server.name` (ServerName) — FQDN веб-сервера;
- `server.ip` — IP-адрес веб-сервера.

> Если соответствующий конфиг уже существует, его значения предлагаются как
> значения по умолчанию (нажмите Enter, чтобы оставить). Повторные вопросы всё
> равно задаются (по вашему выбору), так что легко заменить адреса AD/Exchange.

### 2.4. Распаковка приложения
- Архив распаковывается во временный каталог, находится корень Rails-приложения
  (по `Gemfile`) и копируется в каталог развёртывания **`/var/www/adruby`**
  (переопределяется через `ADRUBY_APP_DIR`).
- Создаются runtime-каталоги `tmp/sessions`, `tmp/cache`, `tmp/pids`, `log`.
- Настраивается владелец `root:www-data`.

### 2.5. Генерация config/infrastructure.yml
- Собранные значения записываются в `config/infrastructure.yml`.
- Копия синхронизируется в `scripts_for_exchange/infrastructure.yml` — её читает
  PowerShell-скрипт создания почтовых ящиков.

### 2.6. Секретный ключ
- Генерируется `/etc/adruby/secret_key` (длина 64 hex-символа, права `600`).
  Его читает `config/environments/production.rb` как `secret_key_base`. Если файл
  уже существует — не перезаписывается.

### 2.7. Установка gem'ов и сборка assets
- `bundle install` от имени `www-data` (в `vendor/bundle`, группы `without:
  development test`), `bundle exec rails assets:precompile`.
- Если первая попытка падает — автоматический повтор.

### 2.8. Настройка Apache + Passenger
- Создаётся **самоподписанный SSL-сертификат** (`/etc/ssl/certs/adruby.pem`,
  `/etc/ssl/private/adruby.key`), если его ещё нет.
- Пишется виртуальный хост `/etc/apache2/sites-available/adruby.conf`:
  - HTTP(:80) → редирект на HTTPS(:443);
  - `PassengerAppEnv production`, `PassengerAppRoot /var/www/adruby`,
    `PassengerRuby /usr/bin/ruby`;
  - HTTPS с SSL; `AstraMode off` (совместимость с Astra Linux);
- Отключается `000-default`, включается сайт `adruby`, проверяется
  `apachectl configtest`.

### 2.9. Запуск и проверка
- Перезапуск `apache2`, рестарт Passenger-приложения
  (`passenger-config restart-app`, `tmp/restart.txt`).
- Выводятся адреса доступа и производится пробный HTTP-запрос к корню.

---

## 3. Результат

После успешного запуска на целевом сервере:

```
/var/www/adruby/                    каталог приложения
/var/www/adruby/config/infrastructure.yml         конфиг инфраструктуры
/var/www/adruby/scripts_for_exchange/infrastructure.yml   копия для Exchange
/etc/adruby/secret_key              секретный ключ Rails
/etc/apache2/sites-available/adruby.conf           vhost
/etc/ssl/certs/adruby.pem           самоподписанный сертификат
```

URL приложения: `https://<ServerName>` (или `http://<IP>`).

---

## 4. Неинтерактивный запуск и переменные окружения

Для полностью автоматического деплоя (например, в Ansible/скриптах) можно
пропустить вопросы. Если `config/infrastructure.yml` уже существует на сервере —
его значения будут взяты автоматически. На «чистой» машине значения можно задать
переменными окружения.

| Переменная | Назначение |
|---|---|
| `ADRUBY_APP_DIR` | каталог развёртывания (по умолчанию `/var/www/adruby`) |
| `ADRUBY_SERVER_NAME` / `ADRUBY_SERVER_IP` | ServerName / IP для Apache |
| `ADRUBY_SKIP_BUILD=1` | пропустить установку окружения (только деплой) |
| `ADRUBY_SKIP_CONF=1` | не переспрашивать инфраструктуру; если файл уже есть — оставить |
| `ADRUBY_NONINTERACTIVE=1` | не задавать вопросов, брать значения конфига/env/дефолты |

Переменные инфраструктуры (приоритет: env → существующий конфиг → дефолт):
`ADRUBY_ORG_NAME`, `ADRUBY_AD_HOST`, `ADRUBY_AD_PORT`, `ADRUBY_AD_BASE`,
`ADRUBY_TERMINATED_OU`, `ADRUBY_DOMAIN`, `ADRUBY_DEFAULT_PWD`,
`ADRUBY_EXCHANGE_SERVER`, `ADRUBY_EXCHANGE_IP`, `ADRUBY_MAILBOX_DB`,
`ADRUBY_PRIMARY_DOMAIN`, `ADRUBY_SECONDARY_DOMAIN`, а также
`ADRUBY_EXCLUDED_OUS` — список OU-исключений через запятую.

Пример:

```bash
ADRUBY_NONINTERACTIVE=1 \
ADRUBY_AD_HOST=10.0.0.5 ADRUBY_AD_BASE='OU=Users,DC=corp,DC=local' \
ADRUBY_EXCLUDED_OUS='OU=Уволенные,OU=Служебные' \
  sudo bash setup.sh ./adruby-app-....tar.gz
```

---

## 5. Частые ситуации и решение

| Ситуация | Решение |
|---|---|
| `Не найден архив приложения` | Передайте путь явно: `sudo bash setup.sh /opt/adruby-app-....tar.gz` |
| `Rails не найден`, долгая установка | Нормально для свежей системы: Rails ставится из gem (несколько минут) |
| Passenger-модуль не собрался | Установите вручную `libapache2-mod-passenger` (apt) либо запустите `passenger-install-apache2-module` и подключите директивы |
| После деплоя `500` / приложение не стартует | Смотрите логи: `/var/log/apache2/adruby_error.log`, `/var/www/adruby/log/production.log` |
| Изменились адреса AD/Exchange | Перезапустите `setup.sh` — вопросы покажут старые значения как дефолты, нажмите Enter или введите новые |

---

## 6. См. также

- [`deploy/README.md`](deploy/README.md) — исторические скрипты деплоя и диагностики;
- [`adruby-app/README.md`](adruby-app/README.md) — описание приложения и роли
  `config/infrastructure.yml`;
- [`exchange/README.md`](exchange/README.md) — настройка скрипта создания почтовых
  ящиков на Exchange.
