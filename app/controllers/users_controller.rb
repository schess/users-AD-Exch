# frozen_string_literal: true

class UsersController < ApplicationController
  before_action :require_login
  before_action :ad_service

  # Delete - step 1: lookup form with autocomplete
  def delete_form
  end

  # Autocomplete endpoint returning JSON list
  def autocomplete
    q = params[:q].to_s.strip
    results = q.empty? ? [] : ad_service.autocomplete(q)
    render json: results.map { |u| { name: u[:display_name], login: u[:sam], dn: u[:dn] } }
  end

  # Delete - step 2: show user info + red confirmation button
  def confirm_delete
    @user = ad_service.user_info(params[:dn])
    if @user.nil?
      flash[:error] = I18n.t("flash.user_not_found")
      redirect_to users_delete_path
    end
  end

  # Delete - step 3: disable and move, show result page
  def perform_delete
    @result = ad_service.disable_and_move(params[:dn])
    @user   = ad_service.user_info(@result[:new_dn])
    render :delete_result
  end

  # Info - step 1: search form (surname / first name / login) with autocomplete
  def info_form
  end

  # Info - step 2: show full information about the user
  def info
    @user = ad_service.user_info(params[:dn])
    if @user.nil?
      flash[:error] = I18n.t("flash.user_not_found")
      redirect_to users_info_path
    end
  end

  # Edit - step 1: search form (surname / first name / login) with autocomplete
  def edit_form
  end

  # Edit - step 2: show editable form pre-filled from AD
  def edit
    @dn   = params[:dn]
    @user = ad_service.user_info(@dn)
    if @user.nil?
      flash[:error] = I18n.t("flash.user_not_found")
      redirect_to users_edit_path
    end
  end

  # Edit - step 3: read-only confirmation of the changes
  def edit_confirm
    @dn     = params[:dn]
    @user   = ad_service.user_info(@dn)
    @attrs  = edit_params
    @changes = {}

    if @user.nil?
      flash[:error] = I18n.t("flash.user_not_found")
      return redirect_to users_edit_path
    end

    @attrs.each do |k, v|
      new_val = v.to_s.strip
      old_val = @user[k].to_s
      @changes[k] = { old: old_val, new: new_val } if old_val != new_val
    end
  end

  # Edit - step 4: write the changes to AD and show the result page
  def perform_edit
    @result = ad_service.update_user(dn: params[:dn], attrs: edit_params)
    target  = @result[:new_dn] || params[:dn]
    @user   = ad_service.user_info(target) if @result[:success]
    render :edit_result
  end

  # Create - form
  def new
    @ous = ad_service.list_ous
  end

  # Create - submit
  def create
    @params = user_params
    @ous    = ad_service.list_ous

    unless all_present?
      @error = I18n.t("flash.fill_all_fields")
      return render :new
    end

    unless @params[:username]&.match?(/\A[a-z0-9.]+\z/i)
      @error = I18n.t("flash.username_invalid")
      return render :new
    end

    unless @params[:patronymic]&.match?(/\A[A-Za-zА-Яа-яЁё]\z/)
      @error = I18n.t("flash.patronymic_invalid")
      return render :new
    end

    @created = ad_service.create_user(
      surname:    @params[:surname],
      name:       @params[:name],
      patronymic: @params[:patronymic],
      username:   @params[:username],
      title:      @params[:title],
      ou:         @params[:ou]
    )

    if @created[:success]
      @created[:password] = AdService::DEFAULT_PWD
      @created[:domain]   = AdService::DOMAIN
      render :create_result
    else
      @error = if @created[:duplicate]
                 @created[:error]
               else
                 I18n.t("flash.create_error", error: @created[:error])
               end
      render :new
    end
  end

  private

  def user_params
    params.permit(:surname, :name, :patronymic, :username, :title, :ou).to_h.symbolize_keys
  end

  def edit_params
    params.permit(:surname, :name, :patronymic, :title, :department, :company, :office, :phone, :mobile).to_h.symbolize_keys
  end

  def all_present?
    %i[surname name patronymic username title ou].all? do |k|
      @params[k].present?
    end
  end
end
