# frozen_string_literal: true

require "net/ldap"
require "openssl"

# Service that encapsulates all Active Directory operations for AD-Ruby.
#
# Infrastructure values (domain, AD host, Exchange mail domains) are read from
# the central config/config/infrastructure.yml (loaded into
# Rails.application.config.infrastructure by config/initializers/infrastructure.rb)
# instead of being hardcoded here.
class AdService
  INFRA = (Rails.application.config.infrastructure || {})

  AD_HOST      = INFRA.dig(:ad, :host)
  AD_PORT      = INFRA.dig(:ad, :port) || 636
  BASE         = INFRA.dig(:ad, :base)
  TERMINATED   = INFRA.dig(:ad, :terminated_ou)
  DOMAIN       = INFRA.dig(:ad, :domain)
  DEFAULT_PWD  = INFRA.dig(:ad, :default_password)
  ORG_NAME     = INFRA.dig(:organization, :name)

  # ---- Editable user attributes (field => LDAP attribute) -------------------
  EDITABLE_ATTRS = {
    title:      :title,
    department: :department,
    company:    :company,
    office:     :physicaldeliveryofficename,
    phone:      :telephonenumber,
    mobile:     :mobile
  }.freeze

  # Фамилия / имя / отчество хранятся в отдельных атрибутах и, кроме того,
  # входят в CN (RDN) объекта, поэтому при их изменении объект переименовывается.
  NAME_FIELDS = %i[surname name patronymic].freeze

  # ---- Exchange mailbox domains (informational) ----------------------------
  # The app does NOT write mailbox attributes itself anymore: that caused
  # Exchange to type users as UserMailbox (msExchRecipientTypeDetails=1) with a
  # bogus mailbox (no msExchMailboxGuid -> OWA ObjectNotFoundException) and made
  # Enable-Mailbox refuse to run. Real mailboxes are created by the scheduled
  # Exchange script (exchange/enable_mailboxes.ps1) via Enable-Mailbox, which
  # sets the correct primary (MAIL_DOMAIN) and secondary (MAIL_DOMAIN_ALT).
  MAIL_DOMAIN      = INFRA.dig(:exchange, :primary_domain)
  MAIL_DOMAIN_ALT  = INFRA.dig(:exchange, :secondary_domain)

  # Path to the audit log (relative to Rails root)
  AUDIT_LOG_PATH = File.expand_path("../../log/audit.log", __dir__)

  attr_reader :ldap

  def initialize(login, password)
    @login    = login.to_s.strip
    @password = password
    @ldap     = build_ldap
  end

  # UPN form of the bind login (user -> user@domain)
  def upn
    @login.include?("@") ? @login : "#{@login}@#{DOMAIN}"
  end

  def authenticated?
    @ldap.bind
  end

  # Write an entry to the audit log
  def audit_log(action:, target:, details:)
    FileUtils.mkdir_p(File.dirname(AUDIT_LOG_PATH))
    File.open(AUDIT_LOG_PATH, "a") do |f|
      f.puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] user=#{@login} action=#{action} target=#{target} #{details}"
    end
  rescue => e
    Rails.logger.error("Audit log write failed: #{e.message}") if defined?(Rails)
  end

  # ---- Menu helpers ---------------------------------------------------------

  # List ALL organizational units under the users base (every nesting level),
  # each labelled with its full OU path (top -> bottom) for clarity.
  def list_ous
    ous = []
    @ldap.search(
      base: BASE,
      scope: Net::LDAP::SearchScope_WholeSubtree,
      filter: Net::LDAP::Filter.eq(:objectclass, "organizationalUnit"),
      attributes: %w[cn distinguishedName]
    ) do |e|
      dn = e.dn
      ous << { dn: dn, name: ou_label(dn) }
    end
    ous.sort_by { |o| o[:name].downcase }
  end

  # Human-readable OU path from a DN, e.g.
  # "OU=Leaf,OU=Middle,OU=Top,OU=Users,DC=corp,DC=local" -> "Top / Middle / Leaf"
  def ou_label(dn)
    if dn == BASE
      rel = BASE.split(",", 2).first.sub(/\A(OU|CN)=/i, "") # the base OU itself -> "Users"
    elsif dn.end_with?(",#{BASE}")
      rel = dn[0..-(BASE.length + 2)]
    else
      rel = dn
    end
    parts = rel.split(",").map { |p| p.sub(/\A(OU|CN)=/i, "") }
    parts.reverse.join(" / ")
  end

  # ---- Delete flow ----------------------------------------------------------

  # Autocomplete: find person users matching query in surname / first name / login.
  def autocomplete(query)
    escaped = Net::LDAP::Filter.escape(query)
    filter = Net::LDAP::Filter.construct(
      "(&(objectCategory=person)(objectClass=user)" \
      "(|(sn=*#{escaped}*)(givenName=*#{escaped}*)(displayName=*#{escaped}*)(sAMAccountName=*#{escaped}*)))"
    )
    users = []
    @ldap.search(
      base: BASE,
      scope: Net::LDAP::SearchScope_WholeSubtree,
      filter: filter,
      attributes: %w[cn sn givenName displayName sAMAccountName distinguishedName title department]
    ) do |e|
      users << {
        display_name: e[:displayname]&.first || e[:cn]&.first,
        sam:          e[:samaccountname]&.first,
        dn:           e.dn,
        title:        e[:title]&.first,
        department:   e[:department]&.first
      }
    end
    users
  end

  # Fetch a single entry by DN.
  def user_by_dn(dn)
    entry = nil
    @ldap.search(base: dn, scope: Net::LDAP::SearchScope_BaseObject) { |e| entry = e }
    entry
  end

  # Present full user info as a hash for the confirm / result / info pages.
  # Fetches a rich set of attributes (mailbox, email addresses, contact details…).
  def user_info(dn)
    e = user_by_dn(dn)
    return nil unless e

    primary_mail = Array(e[:mail]).map(&:to_s).find { |m| !m.empty? }
    proxies = Array(e[:proxyaddresses]).map(&:to_s)
              .map { |a| a.sub(/\A\s*[Ss][Mm][Tt][Pp]:/, "") }.reject(&:empty?)
    primary_mail ||= proxies.first
    aliases = proxies.reject { |a| a.casecmp?(primary_mail.to_s) }

    manager_dn = Array(e[:manager]).map(&:to_s).first
    manager_name = manager_dn&.sub(/\ACN=([^,]+).*/, '\1')

    # Отчество: реальный middleName, а если не заполнен — средний инициал из ФИО.
    patronymic = e[:middlename]&.first
    full_name  = e[:displayname]&.first || e[:cn]&.first
    patronymic_display = patronymic.presence || patronymic_from_display(full_name)

    {
      full_name:  full_name,
      surname:    e[:sn]&.first,
      name:       e[:givenname]&.first,
      patronymic: patronymic,
      patronymic_display: patronymic_display,
      sam:        e[:samaccountname]&.first,
      upn:        e[:userprincipalname]&.first,
      title:      e[:title]&.first,
      department: e[:department]&.first,
      company:    e[:company]&.first,
      office:     e[:physicaldeliveryofficename]&.first,
      phone:      e[:telephonenumber]&.first,
      mobile:     e[:mobile]&.first,
      email:      primary_mail,
      aliases:    aliases.uniq,
      mailbox:    !Array(e[:msexchmailboxguid]).empty?,
      manager:    manager_name,
      created:    e[:whencreated]&.first,
      dn:         e.dn,
      ou:         e.dn[e.dn.index(/OU=|CN=/)..] || e.dn,
      disabled:   ((e[:useraccountcontrol]&.first.to_i) & 2) != 0
    }
  end

  # Disable the account then move it to the terminated-staff OU.
  def disable_and_move(dn)
    e = user_by_dn(dn)
    uac = e[:useraccountcontrol]&.first.to_i
    new_uac = uac | 2 # 0x2 = ACCOUNTDISABLE

    disable_ok = @ldap.modify(
      dn: dn,
      operations: [[:replace, :useraccountcontrol, [new_uac.to_s]]]
    )

    rdn = dn.split(",", 2).first # e.g. CN=Иванов Иван И.
    # AD requires DeleteOldRdn=true when the new RDN equals the old RDN
    # (we only change the parent OU, keeping the same CN), otherwise it
    # returns LDAP error 0x57 "Old RDN must be deleted".
    move_ok = @ldap.rename(
      olddn: dn,
      newrdn: rdn,
      delete_attributes: true,
      new_superior: TERMINATED
    )

    new_dn = "#{rdn},#{TERMINATED}"
    msg = ldap_error_message

    # Audit log
    target_info = user_info(dn)
    audit_log(
      action: "delete_user",
      target: dn,
      details: "full_name=#{target_info&.dig(:full_name)} sam=#{target_info&.dig(:sam)} disabled=#{disable_ok} moved=#{move_ok}"
    )

    {
      disable_ok: disable_ok,
      move_ok:    move_ok,
      new_dn:     new_dn,
      error:      (msg unless disable_ok && move_ok)
    }
  end

  # ---- Edit flow ------------------------------------------------------------

  # Обновляет редактируемые атрибуты пользователя (в т.ч. ФИО). Принимает только
  # поля, значения которых действительно изменились; пустое поле очищает атрибут.
  # Если изменились Фамилия / Имя / Отчество — объект переименовывается (новый
  # CN/DN), т.к. ФИО входит в RDN. Возвращает hash с полями :changes
  # (field => old/new), :new_dn и :error.
  def update_user(dn:, attrs: {})
    entry = user_by_dn(dn)
    return { success: false, error: "Пользователь не найден в Active Directory", changes: {}, new_dn: dn } unless entry

    operations = []
    changes    = {}
    renamed    = false
    result_dn  = dn

    # --- Обычные редактируемые атрибуты (должность, отдел, контакты) ---------
    EDITABLE_ATTRS.each do |key, ldap_name|
      raw = attrs[key]
      next if raw.nil?

      new_val = raw.to_s.strip
      old_val = Array(entry[ldap_name]).map(&:to_s).first.to_s
      next if old_val == new_val

      operations << [:replace, ldap_name, (new_val.empty? ? [] : [new_val])]
      changes[key] = { old: old_val.presence, new: new_val.presence }
    end

    # --- Фамилия / Имя / Отчество -------------------------------------------
    old_full = (entry[:displayname]&.first || entry[:cn]&.first).to_s
    old_sn   = Array(entry[:sn]).map(&:to_s).first.to_s
    old_giv  = Array(entry[:givenname]).map(&:to_s).first.to_s
    old_mid  = Array(entry[:middlename]).map(&:to_s).first.to_s

    sn  = attrs[:surname].nil? ? old_sn : attrs[:surname].to_s.strip
    giv = attrs[:name].nil? ? old_giv : attrs[:name].to_s.strip
    mid = attrs[:patronymic].nil? ? old_mid : attrs[:patronymic].to_s.strip

    # Фамилия и Имя — обязательные поля: попытку очистить их игнорируем.
    sn  = old_sn if sn.empty?
    giv = old_giv if giv.empty?

    new_full = build_full_name(sn, giv, mid)

    # Фиксируем изменения ФИО по отдельности
    changes[:surname]    = { old: old_sn.presence, new: sn.presence }    unless old_sn == sn
    changes[:name]       = { old: old_giv.presence, new: giv.presence }  unless old_giv == giv
    changes[:patronymic] = { old: old_mid.presence, new: mid.presence }  unless old_mid == mid

    if sn.present? && giv.present? && (sn != old_sn || giv != old_giv || mid != old_mid)
      # Обновляем displayName всегда (вне зависимости от того, какие части изменились)
      operations << [:replace, :displayname, [new_full]]
      # Атрибуты ФИО (значения, которые реально изменились)
      operations << [:replace, :sn, [sn]]         unless old_sn == sn
      operations << [:replace, :givenname, [giv]] unless old_giv == giv
      operations << [:replace, :middlename, mid.empty? ? [] : [mid]] unless old_mid == mid
      changes[:full_name] = { old: old_full.presence, new: new_full }
    end

    # --- Применяем изменения -------------------------------------------------
    if operations.empty?
      return { success: true, no_changes: true, changes: changes, new_dn: dn, error: nil }
    end

    # Если ФИО изменилось — сначала переименовываем объект (новый CN/DN).
    if sn.present? && giv.present? && new_full != old_full
      parent = parent_of(dn)
      ok = @ldap.rename(
        olddn: dn,
        newrdn: "CN=#{new_full}",
        delete_attributes: true,
        new_superior: parent
      )
      unless ok
        audit_log(action: "update_user_rename_failed", target: dn,
                  details: "new_cn=#{new_full} error=#{ldap_error_message}")
        return { success: false, error: "Ошибка переименования учётной записи: #{ldap_error_message}", changes: changes, new_dn: dn }
      end
      renamed    = true
      result_dn  = "CN=#{new_full},#{parent}"
    end

    if operations.any?
      ok = @ldap.modify(dn: result_dn, operations: operations)
      unless ok
        audit_log(action: "update_user_modify_failed", target: result_dn,
                  details: "new_cn=#{new_full} error=#{ldap_error_message}")
        return { success: false, error: "Ошибка сохранения изменений: #{ldap_error_message}", changes: changes, new_dn: result_dn }
      end
    end

    audit_log(
      action: "update_user",
      target: dn,
      details: "new_dn=#{result_dn} renamed=#{renamed} changes=#{changes.map { |k, v| "#{k}:#{v[:old] || ''}=>#{v[:new] || ''}" }.join('|')}"
    )

    {
      success:   true,
      no_changes: false,
      renamed:   renamed,
      changes:   changes,
      new_dn:    result_dn,
      error:     nil
    }
  end

  # ---- Name helpers ----------------------------------------------------------

  # Полное ФИО (для displayName / CN). Отчество: одиночная буква -> «И.»,
  # полное слово — как есть. Пустые части отбрасываются.
  def build_full_name(surname, name, patronymic)
    parts = []
    parts << surname.to_s.strip unless surname.to_s.strip.empty?
    parts << name.to_s.strip unless name.to_s.strip.empty?
    p = patronymic.to_s.strip
    unless p.empty?
      parts << (p =~ /\A[A-Za-zА-Яа-яЁё]\z/ ? "#{p}." : p)
    end
    parts.join(" ")
  end

  # Отчество из полного ФИО (для fallback-отображения, если middleName не заполнен).
  # Формат «Фамилия Имя Отчество.» — отчество это 3-е слово.
  def patronymic_from_display(full_name)
    full_name.to_s.strip.split(" ")[2] || ""
  end

  # Родительский контейнер (OU) DN, например
  # "CN=...,OU=Отдел,OU=Users,DC=corp,DC=local" -> "OU=Отдел,OU=Users,DC=corp,DC=local"
  def parent_of(dn)
    parts = dn.to_s.split(",", 2)
    parts.length == 2 ? parts[1] : ""
  end

  # ---- Create flow ----------------------------------------------------------

  # Проверяем, не занят ли логин (sAMAccountName или UPN) в Active Directory.
  # Возвращает true, если такой логин уже существует.
  def username_exists?(username)
    escaped = Net::LDAP::Filter.escape(username)
    filter = Net::LDAP::Filter.construct(
      "(&(objectClass=user)(|(sAMAccountName=#{escaped})(userPrincipalName=#{escaped}@#{DOMAIN})))"
    )
    exists = false
    @ldap.search(
      base: BASE,
      scope: Net::LDAP::SearchScope_WholeSubtree,
      filter: filter,
      attributes: %w[sAMAccountName userPrincipalName]
    ) do |_e|
      exists = true
      false # остановиться после первой найденной записи
    end
    exists
  end

  # Проверяем, не существует ли уже в выбранном подразделении (OU) пользователь
  # с таким же ФИО (CN). Ошибка LDAP 00002071 (ENTRY_EXISTS) возникает именно из-за
  # совпадения CN в одном OU — смена логина её не решает.
  def full_name_exists?(full_name, ou)
    escaped = Net::LDAP::Filter.escape(full_name)
    filter = Net::LDAP::Filter.construct("(&(objectClass=user)(cn=#{escaped}))")
    exists = false
    @ldap.search(
      base: ou,
      scope: Net::LDAP::SearchScope_SingleLevel,
      filter: filter,
      attributes: %w[cn sAMAccountName]
    ) do |_e|
      exists = true
      false # остановиться после первой найденной записи
    end
    exists
  end

  # Отдел пользователя = название выбранной (листовой) OU. Извлекаем имя самого
  # OU из переданного DN, например:
  #   "OU=Отдел кадров,OU=Users,DC=corp,DC=local" -> "Отдел кадров"
  def department_from_ou(dn)
    part = dn.to_s.split(",").find { |p| p =~ /\AOU=/i }
    part ? part.sub(/\AOU=/i, "") : ""
  end

  def create_user(surname:, name:, patronymic:, username:, title:, ou:, department: nil)
    full_name = [surname, name, "#{patronymic}."].join(" ").strip
    dn        = "CN=#{full_name},#{ou}"

    # Если в выбранном OU уже есть пользователь с таким же ФИО (CN) — создание
    # невозможно (DN совпадёт), и смена логина это не исправит. Сообщаем сразу.
    if full_name_exists?(full_name, ou)
      audit_log(
        action: "create_user_fullname_rejected",
        target: dn,
        details: "username=#{username} full_name=#{full_name} ou=#{ou}"
      )
      return {
        success: false,
        duplicate: true,
        error: "В подразделении «#{department_from_ou(ou)}» уже существует пользователь с ФИО «#{full_name}». Измените ФИО или выберите другое подразделение.",
        full_name: full_name,
        username: username,
        ou: ou
      }
    end

    # Если логин (sAMAccountName/UPN) уже существует в AD — не пытаемся создать
    # (иначе LDAP add вернёт ошибку), а сразу сообщаем пользователю.
    if username_exists?(username)
      audit_log(
        action: "create_user_duplicate_rejected",
        target: dn,
        details: "username=#{username} full_name=#{full_name} ou=#{ou}"
      )
      return {
        success: false,
        duplicate: true,
        error: "Логин «#{username}» уже существует в Active Directory. Придумайте другой логин.",
        full_name: full_name,
        username: username,
        ou: ou
      }
    end

    # Отдел берём из названия выбранного OU (leaf), если не передан явно.
    department ||= department_from_ou(ou)

    attrs = {
      objectclass:         %w[top person organizationalPerson user],
      cn:                  full_name,
      sn:                  surname,
      givenname:           name,
      displayname:         full_name,
      samaccountname:      username,
      userprincipalname:   "#{username}@#{DOMAIN}",
      title:               title,
      department:          department,
      useraccountcontrol:  "512", # NORMAL_ACCOUNT
      # unicodePwd must be sent as raw UTF-16LE bytes. Tagging the Ruby string
      # as BINARY (ASCII-8BIT) prevents net-ldap from re-encoding it to UTF-8
      # during BER serialization (which corrupted the password bytes and made AD
      # reject the add with "0000001F WILL_NOT_PERFORM").
      unicodepwd:          "\"#{DEFAULT_PWD}\"".encode(Encoding::UTF_16LE).force_encoding(Encoding::BINARY)
    }

    ok = @ldap.add(dn: dn, attributes: attrs)
    msg = ldap_error_message
    must_change = false
    if ok
      # Force password change at next logon (pwdLastSet = 0).
      must_change = @ldap.modify(dn: dn, operations: [[:replace, :pwdlastset, ["0"]]])
    end

    # Audit log
    audit_log(
      action: "create_user",
      target: dn,
      details: "full_name=#{full_name} username=#{username} title=#{title} department=#{department} ou=#{ou} success=#{ok}"
    )

    {
      success: ok,
      dn: dn,
      full_name: full_name,
      username: username,
      sam: username,
      upn: "#{username}@#{DOMAIN}",
      # E-mail is informational: the real mailbox is created by the scheduled
      # Exchange script (enable_mailboxes.ps1) which sets primary @MAIL_DOMAIN.
      email: "#{username}@#{MAIL_DOMAIN}",
      title: title,
      department: department,
      ou: ou,
      must_change: must_change,
      mailbox: { success: nil, pending: true },   # created later by scheduled Exchange script
      error: (msg unless ok)
    }
  end

  # ---- Misc helpers ---------------------------------------------------------

  private

  def build_ldap
    Net::LDAP.new(
      host: AD_HOST,
      port: AD_PORT,
      base: BASE,
      auth: { method: :simple, username: upn, password: @password },
      encryption: { method: :simple_tls, tls_options: { verify_mode: OpenSSL::SSL::VERIFY_NONE } }
    )
  end

  def ldap_error_message
    r = @ldap.get_operation_result
    if r.respond_to?(:error_message)
      r.error_message.nil? || r.error_message.empty? ? r.to_s : r.error_message
    else
      r.to_s
    end
  end
end
