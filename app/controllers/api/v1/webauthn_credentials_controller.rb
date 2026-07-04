# frozen_string_literal: true

class Api::V1::WebauthnCredentialsController < Api::V1::BaseController
  include WebauthnRelyingParty

  CHALLENGE_EXPIRES_IN = 5.minutes

  before_action :ensure_write_scope
  before_action :ensure_mfa_enabled
  before_action :set_webauthn_credential, only: :destroy

  def options
    user = current_resource_owner
    user.ensure_webauthn_id!

    registration_options = webauthn_relying_party.options_for_registration(
      user: {
        id: user.webauthn_id,
        name: user.email,
        display_name: user.display_name
      },
      exclude: user.webauthn_credentials.pluck(:credential_id),
      authenticator_selection: { user_verification: "preferred" },
      attestation: "none"
    )
    challenge_id = SecureRandom.uuid
    Rails.cache.write(
      registration_challenge_cache_key(challenge_id),
      registration_options.challenge,
      expires_in: CHALLENGE_EXPIRES_IN
    )

    render_json({
      challenge_id: challenge_id,
      expires_in_seconds: CHALLENGE_EXPIRES_IN.to_i,
      public_key: registration_options
    })
  end

  def create
    challenge_id = params[:challenge_id].to_s
    challenge = challenge_id.present? ? Rails.cache.read(registration_challenge_cache_key(challenge_id)) : nil

    unless challenge.present?
      render_json({ error: "webauthn_challenge_expired", message: "WebAuthn registration challenge is missing or expired" }, status: :unprocessable_entity)
      return
    end

    Rails.cache.delete(registration_challenge_cache_key(challenge_id))
    credential_payload = webauthn_credential_payload
    credential = webauthn_relying_party.verify_registration(
      credential_payload,
      challenge,
      user_presence: true
    )
    webauthn_credential = current_resource_owner.webauthn_credentials.create!(
      nickname: webauthn_credential_name,
      credential_id: credential.id,
      public_key: credential.public_key,
      sign_count: credential.sign_count,
      transports: webauthn_credential_transports(credential_payload)
    )

    render_json({
      message: "WebAuthn credential registered",
      webauthn_credential: webauthn_credential_response_payload(webauthn_credential)
    }, status: :created)
  rescue WebAuthn::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActionController::BadRequest, ActionController::ParameterMissing
    render_json({ error: "webauthn_registration_failed", message: "WebAuthn credential could not be registered" }, status: :unprocessable_entity)
  end

  def destroy
    credential_id = @webauthn_credential.id
    @webauthn_credential.destroy!

    render json: {
      message: "WebAuthn credential removed",
      webauthn_credential_id: credential_id
    }
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_mfa_enabled
      return if current_resource_owner.otp_required?

      render_json({
        error: "mfa_required",
        message: "MFA must be enabled to manage WebAuthn credentials"
      }, status: :forbidden)
    end

    def set_webauthn_credential
      return if performed?
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @webauthn_credential = current_resource_owner.webauthn_credentials.find(params[:id])
    end

    def registration_challenge_cache_key(challenge_id)
      "api:v1:webauthn_registration:#{current_resource_owner.id}:#{challenge_id}"
    end

    def webauthn_credential_name
      webauthn_credential_params[:nickname]
    end

    def webauthn_credential_transports(credential_payload)
      response = credential_payload["response"] || credential_payload[:response] || {}
      Array(response["transports"] || response[:transports]).compact_blank
    end

    def webauthn_credential_params
      params.fetch(:webauthn_credential, ActionController::Parameters.new).permit(:nickname)
    end

    def webauthn_credential_response_payload(credential)
      {
        id: credential.id,
        nickname: credential.nickname,
        transports: credential.transports,
        last_used_at: credential.last_used_at&.iso8601,
        created_at: credential.created_at.iso8601,
        updated_at: credential.updated_at.iso8601
      }
    end
end
