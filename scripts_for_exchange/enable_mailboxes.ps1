# ============================================================================
#  enable_mailboxes.ps1
#  ---------------------
#  Автоматическое создание почтовых ящиков Exchange для новых пользователей AD.
#
#  Запускать в Exchange Management Shell на сервере Exchange (Exchange 2016/2019).
#  Рекомендуется по расписанию (Task Scheduler), например раз в час.
#
#  Логика отбора:
#    - сканируется всё поддерево базовой OU (где приложение создаёт юзеров);
#    - берутся ВКЛЮЧЁННЫЕ учётные записи user/person,
#    - у которых НЕТ msExchMailboxGuid (то есть реального ящика в БД ещё нет);
#    - исключаются OU уволенных сотрудников и технических учёток.
#
#  Подключение к AD — через ADSI (не зависит от классификации получателя
#  Exchange, поэтому работает, даже если приложение частично записало
#  атрибуты получателя напрямую).
#
#  Значения инфраструктуры (домены, OU, SMTP-домены, БД, сервер, исключаемые OU)
#  берутся из конфига infrastructure.yml рядом со скриптом (единый источник
#  истины проекта) либо из пути, заданного ключом -ConfigPath.
#
#  Работа в планировщике (Task Scheduler): скрипт НЕинтерактивный — не задаёт
#  вопросов и не останавливается. Автоматически включает почтовый ящик всем
#  пользователям, созданным за последние $MaxAgeHours часов (по умолчанию 8).
#  Исключаемые OU (уволенные, технические учётки) берутся из конфига
#  (exchange.excluded_ous), без захардкоженных значений.
#
#  Использование:
#    .\enable_mailboxes.ps1                  # автоматически создать ящики (учётки < 8 ч)
#    .\enable_mailboxes.ps1 -MaxAgeHours 24  # изменить окно по времени
#    .\enable_mailboxes.ps1 -WhatIf          # показать, что будет сделано (без записи)
# ============================================================================

param(
    [string]$ConfigPath      = "",   # путь к infrastructure.yml (если пусто — ищем рядом со скриптом)
    [string]$SearchBase      = "",
    [string]$MailboxDB       = "",
    [string]$MailboxServer   = "",
    [string]$PrimaryDomain   = "",
    [string]$SecondaryDomain = "",
    [string]$LogPath         = "",                      # путь к логу (если пусто — рядом со скриптом)
    [int]$MaxAgeHours        = 8,                       # обрабатывать учётки, созданные за последние N часов
    [switch]$WhatIf                                     # показать, что будет сделано (без записи)
)

# --- Загрузка центрального конфига инфраструктуры (infrastructure.yml) -------
# PowerShell не имеет встроенного YAML-парсера, поэтому для нашего простого и
# контролируемого YAML используем небольшой построчный парсер ниже.
function Get-InfraConfig {
    param([string]$Path)
    $hash = @{}
    $section = $null
    $listKey = $null
    $listSection = $null
    Get-Content -Path $Path -Encoding UTF8 | ForEach-Object {
        $line = $_
        if ($line -match '^\s*(#.*)?$') { return }                       # комментарий/пустая
        if ($line -match '^(\w+):\s*$') {                                # новая секция
            $section = $matches[1]
            if (-not $hash.ContainsKey($section)) { $hash[$section] = @{} }
            $listKey = $null
            return
        }
        if ($null -ne $section -and $line -match '^\s+(\w+):\s*(.*)$') { # key: value
            $key = $matches[1]
            $rest = $matches[2] -replace '[ \t]*#.*$', ''                # убрать inline-комментарий
            $val = $rest.Trim()
            if ($val.Length -ge 2 -and $val[0] -eq '"' -and $val[-1] -eq '"') { $val = $val.Substring(1, $val.Length - 2) }
            elseif ($val.Length -ge 2 -and $val[0] -eq "'" -and $val[-1] -eq "'") { $val = $val.Substring(1, $val.Length - 2) }
            if ($val -eq '') {                                           # начало списка
                $listKey = $key; $listSection = $section
                $hash[$section][$key] = @()
            } else {
                $hash[$section][$key] = $val
                $listKey = $null
            }
            return
        }
        if ($null -ne $listKey -and $line -match '^\s*-\s*(.*)$') {      # элемент списка
            $itemText = $matches[1] -replace '[ \t]*#.*$', ''
            $item = $itemText.Trim()
            if ($item.Length -ge 2 -and $item[0] -eq '"' -and $item[-1] -eq '"') { $item = $item.Substring(1, $item.Length - 2) }
            elseif ($item.Length -ge 2 -and $item[0] -eq "'" -and $item[-1] -eq "'") { $item = $item.Substring(1, $item.Length - 2) }
            $hash[$listSection][$listKey] += $item
            return
        }
    }
    return $hash
}

# Путь к конфигу по умолчанию: рядом со скриптом (только относительный путь)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "infrastructure.yml"
}

if ($ConfigPath -and (Test-Path $ConfigPath)) {
    $infra = Get-InfraConfig $ConfigPath
    $adCfg       = if ($infra.ContainsKey('ad'))       { $infra['ad'] }       else { @{} }
    $exchCfg     = if ($infra.ContainsKey('exchange')) { $infra['exchange'] } else { @{} }
    # Переопределяем значения по умолчанию из внетних параметров, если они не заданы явно
    if (-not $PSBoundParameters.ContainsKey('SearchBase'))      { $SearchBase      = $adCfg['base'] }
    if (-not $PSBoundParameters.ContainsKey('PrimaryDomain'))   { $PrimaryDomain   = $exchCfg['primary_domain'] }
    if (-not $PSBoundParameters.ContainsKey('SecondaryDomain')) { $SecondaryDomain = $exchCfg['secondary_domain'] }
    if (-not $PSBoundParameters.ContainsKey('MailboxDB'))       { $MailboxDB       = $exchCfg['mailbox_db'] }
    if (-not $PSBoundParameters.ContainsKey('MailboxServer'))   { $MailboxServer   = $exchCfg['server'] }
    $excludedFromCfg = @($exchCfg['excluded_ous'])
}

# Конфиг обязателен: без него нет значений инфраструктуры (SearchBase, БД, домены)
if ([string]::IsNullOrWhiteSpace($SearchBase) -or [string]::IsNullOrWhiteSpace($MailboxDB) -or [string]::IsNullOrWhiteSpace($PrimaryDomain)) {
    Write-Host "ERROR: не найден конфиг инфраструктуры infrastructure.yml (ищите его рядом со скриптом или укажите путь через -ConfigPath)." -ForegroundColor Red
    exit 1
}

# OU, для которых ящики НЕ создаём (уволенные, технические учётки) — берутся
# ТОЛЬКО из конфига (exchange.excluded_ous), без захардкоженных значений.
if ($null -eq $excludedFromCfg) { $excludedFromCfg = @() }
$ExcludedOU = @($excludedFromCfg)

# Лог — по умолчанию относительно скрипта (для работы в планировщике без прав админа).
# Отдельный лог в SystemRoot\Logs и прочие абсолютные пути не используются.
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "enable_mailbox.log"
}

function Write-Log([string]$msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
}

# ---------------------------------------------------------------------------
#  Шаг 0. Проверка: есть ли командлеты Exchange (запускается в EMS?)
# ---------------------------------------------------------------------------
if (-not (Get-Command Enable-Mailbox -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: командлет Enable-Mailbox не найден. Запускайте скрипт в Exchange Management Shell (.< ExchangeInstallPath>\bin\RemoteExchange.ps1)." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
#  Шаг 1. ADSI-поиск кандидатов (включённые пользователи без реального ящика)
# ---------------------------------------------------------------------------
Write-Log "=== Запуск: поиск пользователей без почтового ящика в $SearchBase ==="

# userAccountControl: bit 1 (0x2) = ACCOUNTDISABLE. Пропускаем отключённых.
# whenCreated >= (сейчас - MaxAgeHours): показываем только "свежих" пользователей.
$cutoffUtc = (Get-Date).ToUniversalTime().AddHours(-$MaxAgeHours)
$cutoffStr = $cutoffUtc.ToString("yyyyMMddHHmmss") + ".0Z"
$filter = "(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(!(msExchMailboxGuid=*))(whenCreated>=$cutoffStr))"
Write-Log ("Окно поиска: пользователи, созданные с {0} UTC (последние {1} ч)" -f $cutoffUtc.ToString("yyyy-MM-dd HH:mm"), $MaxAgeHours)

$searcher = New-Object System.DirectoryServices.DirectorySearcher
$searcher.SearchRoot      = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$SearchBase")
$searcher.Filter          = $filter
$searcher.SearchScope     = [System.DirectoryServices.SearchScope]::Subtree
$searcher.PageSize        = 1000
$searcher.PropertiesToLoad.AddRange(@("distinguishedName","sAMAccountName","mail","proxyAddresses","userPrincipalName","whenCreated")) | Out-Null

$candidates = @()
try {
    $results = $searcher.FindAll()
} catch {
    Write-Host "ERROR: не удалось выполнить поиск в AD: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

foreach ($r in $results) {
    $dn       = $r.Properties["distinguishedname"] -join ""
    $sam      = $r.Properties["samaccountname"]     -join ""
    $mail     = $r.Properties["mail"]               -join ""
    $upn      = $r.Properties["userprincipalname"]  -join ""
    $proxies  = @($r.Properties["proxyaddresses"])
    $created  = $r.Properties["whencreated"]        -join ""

    # исключаем OU уволенных / тех. учёток (сравнение без учёта регистра)
    $skip = $false
    foreach ($excl in $ExcludedOU) {
        if ($dn -like "*$excl*") { $skip = $true; break }
    }
    if ($skip) { continue }

    $candidates += [PSCustomObject]@{
        DistinguishedName = $dn
        SamAccountName    = $sam
        Mail              = $mail
        UserPrincipalName = $upn
        ProxyAddresses    = $proxies
        Alias             = $sam
        Created           = $created
    }
}
$results.Dispose()
$searcher.Dispose()

Write-Log ("Найдено кандидатов без ящика: {0}" -f $candidates.Count)

if ($candidates.Count -eq 0) {
    Write-Log "Нет пользователей для обработки. Завершение."
    exit 0
}

# ---------------------------------------------------------------------------
#  Шаг 2. Вывод списка найденных пользователей (без ящика) с e-mail
# ---------------------------------------------------------------------------
# E-mail для показа: берём существующий ПЕРВИЧНЫЙ SMTP (прописной SMTP:), иначе логин@PrimaryDomain
function Get-PrimarySmtp([hashtable]$u) {
    $primary = $null
    foreach ($p in $u.ProxyAddresses) {
        # -cmatch (регистрозависимый): только прописной "SMTP:" — это первичный адрес.
        # Строковый "smtp:" в нижнем регистре — это вторичный адрес, его пропускаем.
        if ($p -cmatch '^SMTP:(.+)$') { $primary = $matches[1]; break }
    }
    if (-not $primary) {
        $primary = "{0}@{1}" -f $u.Alias, $PrimaryDomain
    }
    return $primary
}

$i = 0
Write-Host ""
Write-Host ("=== Пользователи без почтового ящика, созданные за последние {0} ч ({1}) ===" -f $MaxAgeHours, $candidates.Count) -ForegroundColor Cyan
Write-Host ("{0,-3} {1,-22} {2,-30} {3,-17} {4}" -f "#", "ЛОГИН", "E-MAIL", "СОЗДАН (UTC)", "OU (кратко)")
Write-Host ("{0,-3} {1,-22} {2,-30} {3,-17} {4}" -f "---", ("-"*22), ("-"*30), ("-"*17), ("-"*18))
foreach ($c in $candidates) {
    $i++
    $email  = Get-PrimarySmtp @{ Alias = $c.Alias; ProxyAddresses = $c.ProxyAddresses }
    # whenCreated вида "20261006080000.0Z" -> "yyyy-MM-dd HH:mm"
    $createdText = "(n/a)"
    if ($c.Created -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})') {
        $createdText = "{0}-{1}-{2} {3}:{4}" -f $matches[1],$matches[2],$matches[3],$matches[4],$matches[5]
    }
    # короткое имя OU из DN (последняя OU перед ,DC=)
    $shortOu = ($c.DistinguishedName -split ',') | Where-Object { $_ -like 'OU=*' } | Select-Object -First 1
    if (-not $shortOu) { $shortOu = "(нет OU)" }
    Write-Host ("{0,-3} {1,-22} {2,-30} {3,-17} {4}" -f $i, $c.SamAccountName, $email, $createdText, $shortOu.Replace("OU=",""))
}

# ---------------------------------------------------------------------------
#  Шаг 3. Автоматическая обработка (работа в планировщике, без интерактива)
# ---------------------------------------------------------------------------
# Скрипт НЕ задаёт вопросов и не останавливается: почтовый ящик включается
# автоматически всем найденным пользователям (созданным за последние
# $MaxAgeHours часов), кроме исключаемых OU из конфига.
Write-Host ""
Write-Host ("Итого к обработке (создание ящика): {0}" -f $candidates.Count) -ForegroundColor Cyan
foreach ($c in $candidates) {
    Write-Host ("  + {0}  ->  {1}" -f $c.SamAccountName, (Get-PrimarySmtp @{ Alias=$c.Alias; ProxyAddresses=$c.ProxyAddresses })) -ForegroundColor Green
}
if ($candidates.Count -eq 0) { Write-Log "Не выбрано ни одного пользователя. Завершение."; exit 0 }

# ---------------------------------------------------------------------------
#  Шаг 4. Создание ящиков
# ---------------------------------------------------------------------------
# Снимает «фантомные» атрибуты получателя, которые приложение пишет напрямую.
# Из-за них Exchange считает пользователя УЖЕ почтовым получателем
# (msExchRecipientTypeDetails=1 => тип UserMailbox), из-за чего Enable-Mailbox
# падает. Реального ящика за этими атрибутами нет (msExchMailboxGuid пуст),
# поэтому данные не теряются — Enable-Mailbox сам создаст корректные атрибуты.
function Clear-MailboxPreviewAttrs([string]$dn) {
    $user = [adsi]"LDAP://$dn"

    # 1) Типовые атрибуты, которые делают получателя "UserMailbox", ЖЁСТКО
    #    обнуляем (присутствие/значение >0 = ящиковый получатель). Это главное
    #    для того, чтобы Enable-Mailbox увидел обычного пользователя.
    foreach ($p in @("msExchRecipientTypeDetails","msExchRemoteRecipientType","msExchUserAccountControl")) {
        if ($user.Properties.Contains($p)) { $user.Properties[$p].Value = 0 }
    }

    # 2) Остальные «витринные» атрибуты ящика просто удаляем.
    foreach ($p in @(
        "homeMDB","msExchHomeServerName","msExchRecipientDisplayType",
        "mail","mailNickname","proxyAddresses","legacyExchangeDN",
        "msExchVersion","msExchPoliciesIncluded","msExchWhenMailboxCreated",
        "mDBUseDefaults"
    )) {
        if ($user.Properties.Contains($p)) { $user.Properties[$p].Clear() }
    }

    $user.CommitChanges()
}

$ok = 0; $fail = 0
foreach ($c in $candidates) {
    $prim = Get-PrimarySmtp @{ Alias = $c.Alias; ProxyAddresses = $c.ProxyAddresses }
    $sec  = "{0}@{1}" -f $c.Alias, $SecondaryDomain

    Write-Log ("[{0}] Enable-Mailbox -> {1} | {2} | DB {3}" -f $c.SamAccountName, $c.DistinguishedName, $prim, $MailboxDB)

    if ($WhatIf) {
        Write-Log ("[WhatIf] OK (только вывод): {0}" -f $prim)
        $ok++
        continue
    }

    try {
        # Убираем фантомные атрибуты, чтобы Enable-Mailbox видел обычного юзера
        Write-Log ("[{0}] Снимаю фантомные атрибуты ящика (UserMailbox -> User)..." -f $c.SamAccountName)
        Clear-MailboxPreviewAttrs $c.DistinguishedName

        Enable-Mailbox -Identity $c.DistinguishedName `
                       -Database  $MailboxDB `
                       -Alias     $c.Alias `
                       -PrimarySmtpAddress $prim `
                       -ErrorAction Stop

        # Добавляем вторичный домен, если ещё не добавлен
        $mbx = Get-Mailbox -Identity $c.DistinguishedName -ErrorAction SilentlyContinue
        if ($mbx) {
            $addrs = @($mbx.EmailAddresses)
            $hasSec = $false
            foreach ($a in $addrs) {
                if ([string]$a -ieq "smtp:$sec") { $hasSec = $true; break }
            }
            if (-not $hasSec) {
                Set-Mailbox -Identity $c.DistinguishedName -EmailAddresses @{add = "smtp:$sec"} -ErrorAction Stop
            }
        }
        Write-Log ("[OK] Ящик создан: {0}" -f $prim)
        $ok++
    } catch {
        Write-Log ("[FAIL] {0} : {1}" -f $c.SamAccountName, $_.Exception.Message)
        $fail++
    }
}

Write-Log "=== Готово. Создано: $ok, Ошибок: $fail ==="
