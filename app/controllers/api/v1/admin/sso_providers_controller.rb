# frozen_string_literal: true

class Api::V1::Admin::SsoProvidersController < Api::V1::BaseController
  SUPPORTED_STRATEGIES = %w[openid_connect google_oauth2 github saml].freeze
  SENSITIVE_SETTINGS_KEYS = %w[
    client_secret
    idp_certificate
    private_key
    private_key_pem
    certificate_password
  ].freeze

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[create update destroy toggle test_connection]
  before_action :ensure_super_admin!
  before_action :set_sso_provider, only: %i[show update destroy toggle test_connection]

  def index
    sso_providers = SsoProvider.order(:name)
    provider_names = sso_providers.pluck(:name)
    legacy_providers = runtime_providers.reject { |provider| provider_names.include?(provider_value(provider, :name).to_s) }

    render_json({
      sso_providers: sso_providers.map { |provider| sso_provider_payload(provider) },
      legacy_providers: legacy_providers.map { |provider| runtime_provider_payload(provider) },
      configuration: configuration_payload
    })
  end

  def show
    render_json({ sso_provider: sso_provider_payload(@sso_provider) })
  end

  def create
    sso_provider = SsoProvider.new(processed_provider_params)
    apply_default_redirect_uri(sso_provider)

    if sso_provider.save
      log_provider_change(:create, sso_provider)
      clear_provider_cache
      render_json({ sso_provider: sso_provider_payload(sso_provider) }, status: :created)
    else
      render_model_errors(sso_provider)
    end
  end

  def update
    attributes = processed_provider_params
    attributes.delete(:client_secret) if attributes[:client_secret].blank?
    attributes[:settings] = merged_settings(attributes[:settings]) if attributes.key?(:settings)

    if attributes[:name].present? && attributes[:name] != @sso_provider.name
      attributes[:redirect_uri] = callback_url(attributes[:name])
    end

    if @sso_provider.update(attributes)
      log_provider_change(:update, @sso_provider)
      clear_provider_cache
      render_json({ sso_provider: sso_provider_payload(@sso_provider) })
    else
      render_model_errors(@sso_provider)
    end
  end

  def destroy
    @sso_provider.destroy!
    log_provider_change(:destroy, @sso_provider)
    clear_provider_cache

    render_json({ message: "SSO provider deleted successfully" })
  end

  def toggle
    @sso_provider.update!(enabled: !@sso_provider.enabled)
    log_provider_change(:toggle, @sso_provider)
    clear_provider_cache

    message = @sso_provider.enabled? ? "SSO provider enabled successfully" : "SSO provider disabled successfully"
    render_json({
      message: message,
      sso_provider: sso_provider_payload(@sso_provider)
    })
  end

  def test_connection
    result = SsoProviderTester.new(@sso_provider).test!

    render_json({
      success: result.success?,
      message: result.message,
      details: result.details || {}
    })
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_super_admin!
      return if performed?
      return if current_resource_owner&.super_admin?

      render_json({
        error: "forbidden",
        message: "SSO providers can only be managed by a super admin"
      }, status: :forbidden)
    end

    def set_sso_provider
      @sso_provider = SsoProvider.find(params[:id])
    end

    def provider_params
      params.require(:sso_provider).permit(
        :strategy,
        :name,
        :label,
        :icon,
        :enabled,
        :issuer,
        :client_id,
        :client_secret,
        :redirect_uri,
        :scopes,
        :prompt,
        settings: [
          :default_role, :scopes, :prompt,
          :idp_metadata_url, :idp_sso_url, :idp_slo_url,
          :idp_certificate, :idp_cert_fingerprint, :name_id_format,
          role_mapping: {}
        ]
      )
    end

    def processed_provider_params
      result = provider_params.to_h.with_indifferent_access

      if result.dig(:settings, :role_mapping).present?
        result[:settings][:role_mapping] = result[:settings][:role_mapping].transform_values do |value|
          Array(value).flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:blank?)
        end

        result[:settings][:role_mapping] = result[:settings][:role_mapping].reject { |_, value| value.empty? }
        result[:settings].delete(:role_mapping) if result[:settings][:role_mapping].empty?
      end

      result
    end

    def apply_default_redirect_uri(sso_provider)
      return if sso_provider.redirect_uri.present? || sso_provider.name.blank?

      sso_provider.redirect_uri = callback_url(sso_provider.name)
    end

    def merged_settings(incoming_settings)
      @sso_provider.settings.to_h.deep_merge((incoming_settings || {}).to_h)
    end

    def sso_provider_payload(provider)
      {
        id: provider.id,
        strategy: provider.strategy,
        name: provider.name,
        label: provider.label,
        icon: provider.icon,
        enabled: provider.enabled?,
        issuer: provider.issuer,
        client_id: provider.client_id,
        client_secret_present: provider.client_secret.present?,
        redirect_uri: provider.redirect_uri,
        callback_url: callback_url(provider.name),
        settings: safe_settings(provider.settings),
        source: "database",
        manageable: true,
        created_at: provider.created_at.iso8601,
        updated_at: provider.updated_at.iso8601
      }
    end

    def runtime_provider_payload(provider)
      name = provider_value(provider, :name).to_s

      {
        name: name,
        strategy: provider_value(provider, :strategy)&.to_s,
        label: provider_value(provider, :label)&.to_s,
        icon: provider_value(provider, :icon)&.to_s,
        enabled: true,
        callback_url: callback_url(name),
        source: "runtime",
        manageable: false
      }
    end

    def configuration_payload
      {
        database_providers_enabled: FeatureFlags.db_sso_providers?,
        supported_strategies: SUPPORTED_STRATEGIES
      }
    end

    def runtime_providers
      Rails.configuration.x.auth.sso_providers || []
    end

    def provider_value(provider, key)
      return unless provider.respond_to?(:[])

      provider[key] || provider[key.to_s]
    end

    def callback_url(name)
      "#{request.base_url}/auth/#{name}/callback"
    end

    def safe_settings(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          key_string = key.to_s
          if SENSITIVE_SETTINGS_KEYS.include?(key_string)
            result["#{key_string}_present"] = child.present?
          else
            result[key_string] = safe_settings(child)
          end
        end
      when Array
        value.map { |child| safe_settings(child) }
      else
        value
      end
    end

    def render_model_errors(record)
      render_json({
        error: "validation_failed",
        message: record.errors.full_messages.to_sentence,
        errors: record.errors.full_messages
      }, status: :unprocessable_entity)
    end

    def log_provider_change(action, provider)
      Rails.logger.info(
        "[Api::V1::Admin::SsoProviders] #{action.to_s.upcase} - " \
        "user_id=#{current_resource_owner.id} " \
        "provider_id=#{provider.id} " \
        "provider_name=#{provider.name} " \
        "strategy=#{provider.strategy} " \
        "enabled=#{provider.enabled}"
      )
    end

    def clear_provider_cache
      ProviderLoader.clear_cache
      Rails.logger.info("[Api::V1::Admin::SsoProviders] Provider cache cleared by user_id=#{current_resource_owner.id}")
    end
end
