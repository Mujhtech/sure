# frozen_string_literal: true

class Api::V1::SsoIdentitiesController < Api::V1::BaseController
  before_action :ensure_write_scope
  before_action :set_sso_identity

  def destroy
    unless can_unlink_sso_identity?
      render_json({
        error: "cannot_unlink_last_identity",
        message: "Cannot unlink the last SSO identity until a password is set"
      }, status: :unprocessable_entity)
      return
    end

    identity_id = @sso_identity.id
    provider_name = @sso_identity.provider
    @sso_identity.destroy!
    SsoAuditLog.log_unlink!(user: current_resource_owner, provider: provider_name, request: request)

    render json: {
      message: "SSO identity unlinked",
      sso_identity_id: identity_id,
      provider: provider_name
    }
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_sso_identity
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @sso_identity = current_resource_owner.oidc_identities.find(params[:id])
    end

    def can_unlink_sso_identity?
      current_resource_owner.oidc_identities.count > 1 || current_resource_owner.password_digest.present?
    end
end
