# frozen_string_literal: true

class Api::V1::ApiKeysController < Api::V1::BaseController
  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[create destroy]
  before_action :set_managed_api_key, only: %i[show destroy]

  def index
    api_keys = current_resource_owner.api_keys.active.visible.order(created_at: :desc)

    render json: {
      api_keys: api_keys.map { |api_key| api_key_payload(api_key) },
      options: api_key_options
    }
  end

  def show
    render json: { api_key: api_key_payload(@managed_api_key) }
  end

  def create
    plain_key = ApiKey.generate_secure_key
    api_key = current_resource_owner.api_keys.build(api_key_params)
    api_key.key = plain_key

    if api_key.save
      render json: {
        api_key: api_key_payload(api_key, plain_key: plain_key)
      }, status: :created
    else
      render_json({
        error: "validation_failed",
        message: "API key could not be created",
        errors: api_key.errors.full_messages
      }, status: :unprocessable_entity)
    end
  end

  def destroy
    @managed_api_key.revoke!

    render json: {
      message: "API key revoked",
      api_key: api_key_payload(@managed_api_key)
    }
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed
    render_json({
      error: "revoke_failed",
      message: "API key could not be revoked"
    }, status: :unprocessable_entity)
  end

  private
    def set_managed_api_key
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @managed_api_key = current_resource_owner.api_keys.active.visible.find(params[:id])
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def api_key_params
      permitted = params.require(:api_key).permit(:name, :scopes, scopes: [])
      if permitted.key?(:scopes)
        permitted[:scopes] = Array(permitted[:scopes]).reject(&:blank?)
      end
      permitted[:source] = "mobile"
      permitted
    end

    def authenticated_api_key
      return unless @authentication_method == :api_key

      instance_variable_get(:@api_key)
    end

    def api_key_payload(api_key, plain_key: nil)
      payload = {
        id: api_key.id,
        name: api_key.name,
        scopes: api_key.scopes,
        source: api_key.source,
        active: api_key.active?,
        current: authenticated_api_key&.id == api_key.id,
        last_used_at: api_key.last_used_at&.iso8601,
        expires_at: api_key.expires_at&.iso8601,
        revoked_at: api_key.revoked_at&.iso8601,
        created_at: api_key.created_at.iso8601,
        updated_at: api_key.updated_at.iso8601
      }
      payload[:plain_key] = plain_key if plain_key.present?
      payload
    end

    def api_key_options
      {
        scopes: %w[read read_write],
        sources: %w[mobile]
      }
    end
end
