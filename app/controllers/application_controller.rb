# frozen_string_literal: true

class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception

  SUPPORTED_LOCALES = %w[ru en de fr].freeze

  before_action :set_locale_from_session

  helper_method :current_login

  # POST /locale — switch UI language for the current session.
  def set_locale
    locale = params[:locale].to_s
    session[:locale] = locale if SUPPORTED_LOCALES.include?(locale)
    I18n.locale = current_locale
    redirect_to request.referer || root_path, notice: I18n.t("flash.locale_changed")
  end

  private

  def set_locale_from_session
    I18n.locale = current_locale
  end

  def current_locale
    loc = session[:locale].to_s
    SUPPORTED_LOCALES.include?(loc) ? loc.to_sym : I18n.default_locale
  end

  def require_login
    return if session[:ad_login].present?

    redirect_to root_path, alert: I18n.t("flash.auth_required")
  end

  def ad_service
    @ad_service ||= AdService.new(session[:ad_login], session[:ad_password])
  end

  def current_login
    session[:ad_login]
  end
end
