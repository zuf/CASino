require 'addressable/uri'
require 'smsc_api'

module CASino::SessionsHelper
  include CASino::TicketGrantingTicketProcessor
  include CASino::ServiceTicketProcessor

  def current_ticket_granting_ticket?(ticket_granting_ticket)
    ticket_granting_ticket.ticket == cookies[:tgt]
  end

  def current_ticket_granting_ticket
    return nil unless cookies[:tgt]
    return @current_ticket_granting_ticket unless @current_ticket_granting_ticket.nil?
    find_valid_ticket_granting_ticket(cookies[:tgt], request.user_agent).tap do |tgt|
      cookies.delete :tgt if tgt.nil?
      @current_ticket_granting_ticket = tgt
    end
  end

  def current_user
    tgt = current_ticket_granting_ticket
    return nil if tgt.nil?
    tgt.user
  end

  def ensure_signed_in
    redirect_to login_path unless signed_in?
  end

  def signed_in?
    !current_ticket_granting_ticket.nil?
  end

  def sign_in(authentication_result, options = {})
    tgt = acquire_ticket_granting_ticket(authentication_result, request.user_agent, request.remote_ip, options)
    create_login_attempt(tgt.user, true)
    set_tgt_cookie(tgt)
    handle_signed_in(tgt, options)
  end

  def set_tgt_cookie(tgt)
    cookies[:tgt] = {value: tgt.ticket}.tap do |cookie|
      if tgt.long_term?
        cookie[:expires] = CASino.config.ticket_granting_ticket[:lifetime_long_term].seconds.from_now
      end
    end
  end

  def sign_out
    remove_ticket_granting_ticket(cookies[:tgt], request.user_agent)
    cookies.delete :tgt
  end

  def log_failed_login(username)
    CASino::User.where(username: username).each do |user|
      create_login_attempt(user, false)
    end
  end

  def create_login_attempt(user, successful)
    user.login_attempts.create! successful: successful,
                                user_ip: request.ip,
                                user_agent: request.user_agent
  end

  private

  def send_sms(user, message)
    raise "Can't send OTP to user with blank phone number: #{user.username} [id: #{user.id}]" if user.phone.blank?

    if Rails.env.production?
      sms = SMSC.new
      ret = sms.send_sms(user.phone, message, 0, 0, 0, 0, CASino.config.sms[:from])
      if ret.size == 2 # ERROR
        id, error_code = ret
        error_text = t("code_#{error_code.to_i.abs}", scope: 'smsc.error_codes', default: '')
        if error_text.present?
          flash[:error] = I18n.t('validate_otp.smsc_error', error: error_text, error_code: error_code)
        else
          raise "Error while sending sms. Error code: #{ret.last}"
        end
      else
        flash[:notice] = I18n.t('validate_otp.password_was_sent_at', time: I18n.l(Time.now, format: :short))
      end
    else
      STDERR.puts "Skip sending SMS in #{Rails.env} environment."
      STDERR.puts "SMS text: #{message}"
      begin
        `notify-send -t 20000 'SMS Message to #{user.phone}' '#{message}'`
      rescue => e
        STDERR.puts "#{e}"
      end
    end

    # @sms = Smsaero::API.new sms_login, sms_password
    # @sms.send user.phone, sms_from, message

    Rails.logger.warn "OTP Send: User: #{user.username} Phone: #{user.phone} Message: #{message}"
  end

  def send_otp_message_to_user(user, secret=nil)
    totp = ROTP::TOTP.new(secret || user.active_two_factor_authenticator.secret)

    send_sms(user, "Ваш пароль: #{totp.now}")
  end

  def handle_signed_in(tgt, options = {})
    if tgt.awaiting_two_factor_authentication?
      @ticket_granting_ticket = tgt

      send_otp_message_to_user @ticket_granting_ticket.user

      render 'casino/sessions/validate_otp'
    else
      if params[:service].present?
        begin
          handle_signed_in_with_service(tgt, options)
          return
        rescue Addressable::URI::InvalidURIError => e
          Rails.logger.warn "Service #{params[:service]} not valid: #{e}"
        end
      end
      redirect_to sessions_path, status: :see_other
    end
  end

  def handle_signed_in_with_service(tgt, options)
    if !service_allowed?(params[:service])
      @service = params[:service]
      render 'casino/sessions/service_not_allowed', status: 403
    else
      url = acquire_service_ticket(tgt, params[:service], options).service_with_ticket_url
      redirect_to url, status: :see_other
    end
  end
end
