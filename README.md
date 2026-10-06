# AD-Ruby — управление учётными записями Active Directory

Веб-приложение на Ruby on Rails для управления учётными записями пользователей
**Active Directory** организации через веб-интерфейс (LDAPS). Почтовые ящики
Microsoft Exchange создаются отдельным скриптом (`scripts_for_exchange/`).

## Возможности

- **Добавление пользователей** — создание учётной записи AD (ФИО, логин,
  должность, отдел, подразделение/OU) с паролем по умолчанию и принудительной
  сменой пароля при первом входе.
- **Удаление (увольнение) пользователей** — поиск по автодополнению, отключение
  учётной записи и перенос в OU уволенных сотрудников.
- **Редактирование** — изменение ФИО, должности, отдела и контактных данных.
- **Просмотр информации** о пользователе (почтовый ящик, алиасы, руководитель…).
- Аудит действий в лог-файле приложения.

Почтовый ящик Exchange выдаётся **не самим приложением**, а отдельным плановым
скриптом `scripts_for_exchange/enable_mailboxes.ps1`, который запускается на
сервере Exchange (Enable-Mailbox). Приложение лишь сообщает ожидаемый e-mail.

## Стек

- **Ruby 3.1**, **Rails 7.2**
- **net-ldap ~> 0.17** — работа с Active Directory по LDAPS
- **sprockets-rails** (asset pipeline), **Puma** (для разработки)
- Продакшен: **Apache + Phusion Passenger**

## Структура

```
app/
  controllers/         # sessions, menu, users
  services/ad_service.rb  # ВСЯ логика работы с AD (LDAP)
  views/               # шаблоны ERB
config/
  routes.rb            # маршруты
  infrastructure.yml   # конфиг инфраструктуры (генерируется setup.sh)
scripts_for_exchange/  # PowerShell-скрипт создания почтовых ящиков + README
setup.sh               # развёртывание на целевом сервере
package.sh             # сборка дистрибутива tar.gz
SETUP.md               # описание развёртывания
```

## Конфигурация инфраструктуры

Все параметры окружения (**не захардкожены** в коде) хранятся в едином файле
`config/infrastructure.yml`:

```yaml
ad:
  host: "<IP контроллера домена / LDAPS>"
  port: 636
  base: "<baseDN OU, где создаются пользователи>"
  terminated_ou: "<полный DN OU уволенных сотрудников>"
  domain: "<домен>"
  default_password: "<пароль по умолчанию>"
exchange:
  server: "<имя сервера Exchange>"
  ip: "<IP>"
  mailbox_db: "<БД ящиков>"
  primary_domain: "<primary SMTP-домен>"
  secondary_domain: "<secondary SMTP-домен>"
  excluded_ous:          # OU, для которых ящики НЕ создаются
    - "<OU 1>"
    - "<OU 2>"
server:
  name: "<FQDN веб-сервера>"
  ip: "<IP веб-сервера>"
```

Файл загружается при старте в `Rails.application.config.infrastructure`
(`config/initializers/infrastructure.rb`) и читается сервисом `AdService`.
Тот же файл использует скрипт Exchange. **Файл содержит пароль — не публикуйте его.**

> ВАЖНО: `config/infrastructure.yml` в этом репозитории **отсутствует** — он
> генерируется автоматически при развёртывании (см. ниже). Присутствует только
> шаблон `config/infrastructure.yml.tpl`.

## Развёртывание

Проект подготовлен к переносу в другую среду (другие IP AD/Exchange, другие OU)
без GitLab/CI. Развёртывание в два шага.

> **Важно про связку `package.sh` → `setup.sh`:**
> В git-репозитории **самого упакованного приложения (`*.tar.gz`) НЕТ** — он
> исключён из версионирования (см. `.gitignore`), потому что это дистрибутив,
> который считается при сборке и содержит в себе secrets-конфиги для конкретного
> окружения. `setup.sh` — это только скрипт развёртывания: он ожидает готовый
> архив `adruby-app-*.tar.gz` (указывается аргументом или лежит рядом со
> скриптом). Чтобы получить архив, его нужно сначала собрать скриптом
> `package.sh` на любой машине с установленным `bash`/`tar`. Собранный архив
> переносится на целевой сервер.

### 1. Сборка дистрибутива (на машине сборки — например, локально или на CI)

```bash
bash package.sh
```

Создаётся архив `adruby-app-ruby-3.1.2-rails-7.2-<дата>-<хэш>.tar.gz`
(секреты и конфиги исключены из архива).

### 2. Установка на целевом сервере (Debian / Ubuntu / Astra Linux SE)

Скопируйте собранный архив на сервер и запустите развёртывание:

```bash
sudo bash setup.sh ./adruby-app-....tar.gz
```

Если архив `adruby-app-*.tar.gz` лежит в той же папке, что и `setup.sh`, путь
можно не указывать — скрипт найдёт его автоматически.

`setup.sh` автоматически:
- устанавливает окружение: **Ruby + gems + Rails + Apache + Phusion Passenger**;
- интерактивно запрашивает всю инфраструктуру: адреса **AD** и **Exchange**,
  **baseDN** OU, OU уволенных, домен, SMTP-домены (и **несколько OU-исключений**);
- генерирует `config/infrastructure.yml` (и копию для Exchange-скрипта);
- разворачивает приложение в `/var/www/adruby`, ставит gem'ы, собирает assets;
- настраивает Apache + Passenger, создаёт самоподписанный SSL-сертификат
  и секретный ключ, запускает и проверяет приложение.

Подробное описание каждого шага, вопросов и неинтерактивного режима — в
[`SETUP.md`](SETUP.md).

## Локальный запуск (разработка)

```bash
bundle install
bin/rails server   # Puma на http://localhost:3000
```

> Для работы нужен реальный Active Directory с LDAPS и настроенный
> `config/infrastructure.yml`.

## Скрипт Exchange

`scripts_for_exchange/enable_mailboxes.ps1` находит новых пользователей AD без
почтового ящика и создаёт их через `Enable-Mailbox`. Запускается в Exchange
Management Shell (по расписанию, например раз в час). Настройки читаются из
`scripts_for_exchange/infrastructure.yml`. Подробности — в
[`scripts_for_exchange/README.md`](scripts_for_exchange/README.md).

## Безопасность

- Пароль пользователя отправляется в AD как **UTF-16LE** (`unicodePwd`), иначе
  AD вернёт `WILL_NOT_PERFORM`.
- `config/infrastructure.yml`, `secrets.yml`, `master.key`, `credentials.yml.enc`
  не хранятся в репозитории и генерируются на сервере.
- Проверяйте, что не публикуете реальные конфиги и секреты (см. `.gitignore`).
