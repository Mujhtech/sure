# frozen_string_literal: true

class Api::V1::MfaController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: %i[setup verify destroy]

  ISSUER = "Sure Finances"

  def show
    render_json({ mfa: mfa_payload(current_resource_owner) })
  end

  def setup
    user = current_resource_owner

    if user.otp_required?
      render_json({ error: "mfa_already_enabled", message: "MFA is already enabled" }, status: :unprocessable_entity)
      return
    end

    user.setup_mfa! if user.otp_secret.blank?

    render_json({
      mfa: mfa_payload(user),
      setup: setup_payload(user)
    }, status: :created)
  end

  def verify
    user = current_resource_owner

    unless user.otp_secret.present? && !user.otp_required?
      render_json({ error: "mfa_setup_required", message: "Start MFA setup before verifying a code" }, status: :unprocessable_entity)
      return
    end

    if user.verify_otp?(params[:code])
      backup_codes = user.enable_mfa!
      render_json({
        message: "MFA enabled",
        mfa: mfa_payload(user),
        backup_codes: backup_codes
      })
    else
      user.disable_mfa!
      render_json({ error: "invalid_code", message: "Verification code is invalid" }, status: :unprocessable_entity)
    end
  end

  def destroy
    current_resource_owner.disable_mfa!

    render_json({
      message: "MFA disabled",
      mfa: mfa_payload(current_resource_owner)
    })
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def mfa_payload(user)
      {
        enabled: user.otp_required?,
        setup_pending: user.otp_secret.present? && !user.otp_required?,
        webauthn_enabled: user.webauthn_enabled?,
        backup_codes_remaining: Array(user.otp_backup_codes).size
      }
    end

    def setup_payload(user)
      {
        issuer: ISSUER,
        account_name: user.email,
        otp_secret: user.otp_secret,
        provisioning_uri: user.provisioning_uri
      }
    end
end
