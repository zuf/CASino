class CASino::User < ActiveRecord::Base
  serialize :extra_attributes, Hash

  has_many :ticket_granting_tickets
  has_many :two_factor_authenticators
  has_many :login_attempts

  after_create :init_two_factor_auth

  def active_two_factor_authenticator
    self.two_factor_authenticators.where(active: true).first
  end

  def init_two_factor_auth
    transaction do
      two_factor_authenticators.where(active: true).delete_all
      @two_factor_authenticator = two_factor_authenticators.create! secret: ROTP::Base32.random_base32, active: true
    end
  end

end
