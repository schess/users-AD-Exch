# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:destroy]

  def new
    redirect_to menu_path if session[:ad_login].present?
  end

  def create
    @login = params[:login].to_s.strip
    @password = params[:password].to_s

    svc = AdService.new(@login, @password)
    if svc.authenticated?
      session[:ad_login]    = @login
      session[:ad_password] = @password
      redirect_to menu_path, notice: I18n.t("sessions.success")
    else
      flash.now[:error] = I18n.t("sessions.failed")
      render :new
    end
  end

  def destroy
    reset_session
    redirect_to root_path, notice: I18n.t("sessions.logout_notice")
  end
end
