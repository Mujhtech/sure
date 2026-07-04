# frozen_string_literal: true

class Api::V1::SecurityController < Api::V1::BaseController
  before_action :ensure_read_scope

  def show
    render json: {
      security: security_payload(current_resource_owner)
    }
  end

  private
    def security_payload(user)
      {
        mfa: {
          enabled: user.otp_required?,
          webauthn_enabled: user.webauthn_enabled?,
          backup_codes_remaining: Array(user.otp_backup_codes).size
        },
        local_authentication: {
          password_enabled: user.has_local_password?,
          sso_only: user.sso_only?
        },
        webauthn_credentials: user.webauthn_credentials.order(created_at: :asc).map do |credential|
          webauthn_credential_payload(credential)
        end,
        sso_identities: user.oidc_identities.order(:provider).map do |identity|
          sso_identity_payload(identity, user)
        end,
        sso_providers: sso_provider_payloads,
        encryption: {
          unconfigured: Rails.application.config.app_mode.self_hosted? &&
            !ActiveRecordEncryptionConfig.explicitly_configured?
        }
      }
    end

    def webauthn_credential_payload(credential)
      {
        id: credential.id,
        nickname: credential.nickname,
        transports: credential.transports,
        last_used_at: credential.last_used_at&.iso8601,
        created_at: credential.created_at.iso8601,
        updated_at: credential.updated_at.iso8601
      }
    end

    def sso_identity_payload(identity, user)
      config = identity.provider_config || {}
      label = config[:label].presence || config["label"].presence || identity.provider.to_s.titleize
      icon = config[:icon].presence || config["icon"].presence || "key"

      {
        id: identity.id,
        provider: identity.provider,
        label: label,
        icon: icon,
        email: identity.info&.dig("email"),
        last_authenticated_at: identity.last_authenticated_at&.iso8601,
        can_unlink: can_unlink_sso_identity?(user),
        created_at: identity.created_at.iso8601,
        updated_at: identity.updated_at.iso8601
      }
    end

    def sso_provider_payloads
      AuthConfig.sso_providers.map do |provider|
        name = provider[:name].presence || provider["name"].presence || provider[:id].presence || provider["id"]
        next if name.blank?

        {
          name: name,
          label: provider[:label].presence || provider["label"].presence || name.to_s.titleize,
          icon: provider[:icon].presence || provider["icon"].presence || "key",
          strategy: provider[:strategy].presence || provider["strategy"],
          mobile_sso_start_path: "/auth/mobile/#{name}"
        }
      end.compact
    end

    def can_unlink_sso_identity?(user)
      user.oidc_identities.count > 1 || user.password_digest.present?
    end
end
