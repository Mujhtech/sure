# frozen_string_literal: true

class Api::V1::ProviderSettingsController < Api::V1::BaseController
  REDACTED_SECRET_PLACEHOLDER = "********"

  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: :update
  before_action :ensure_admin

  def show
    render_provider_settings
  end

  def update
    updated_fields = []

    Setting.transaction do
      provider_settings_attributes.each do |param_key, param_value|
        field = registered_provider_fields[param_key.to_s]
        next unless field
        next if field.secret && param_value.to_s.strip == REDACTED_SECRET_PLACEHOLDER

        write_provider_setting(field.setting_key, normalized_setting_value(param_value))
        updated_fields << field.setting_key.to_s
      end
    end

    reload_provider_configs(updated_fields)

    render_provider_settings(
      message: updated_fields.any? ? "Provider settings updated" : "No provider settings changed",
      updated_fields: updated_fields
    )
  rescue ActionController::ParameterMissing => e
    handle_bad_request(e)
  rescue StandardError => e
    Rails.logger.error("ProviderSettingsController#update error: #{e.class} - #{e.message}")

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_admin
      return if current_resource_owner.admin?

      render_json({
        error: "forbidden",
        message: "Provider settings can only be changed by an admin"
      }, status: :forbidden)
    end

    def render_provider_settings(message: nil, updated_fields: nil)
      payload = {
        provider_settings: provider_settings_payload,
        options: {
          redacted_secret_placeholder: REDACTED_SECRET_PLACEHOLDER
        }
      }
      payload[:message] = message if message.present?
      payload[:updated_fields] = updated_fields if updated_fields

      render_json(payload)
    end

    def provider_settings_payload
      load_provider_configurations

      Provider::ConfigurationRegistry.all.map do |configuration|
        provider_setting_payload(configuration)
      end
    end

    def provider_setting_payload(configuration)
      provider_key = configuration.provider_key.to_s
      metadata = Provider::Metadata.for(provider_key)

      {
        provider: provider_key,
        name: metadata[:name] || provider_key.titleize,
        description: configuration.provider_description,
        configured: configuration.configured?,
        metadata: {
          region: metadata[:region],
          kinds: Array(metadata[:kinds]),
          maturity: metadata[:maturity]&.to_s,
          tier: metadata[:tier]
        }.compact,
        fields: configuration.fields.map { |field| provider_field_payload(field) }
      }
    end

    def provider_field_payload(field)
      value_info = provider_field_value_info(field)
      payload = {
        name: field.name.to_s,
        setting_key: field.setting_key.to_s,
        label: field.label,
        description: field.description,
        required: field.required,
        secret: field.secret,
        env_key: field.env_key,
        env_present: value_info[:env_present],
        configured: field.present?,
        value_source: value_info[:source],
        default: field.secret ? nil : field.default,
        errors: field.validate
      }

      payload[:value] = field.value unless field.secret
      payload
    end

    def provider_field_value_info(field)
      setting_value = Setting[field.setting_key]
      env_value = field.env_key.present? ? ENV[field.env_key] : nil

      source =
        if setting_value.present?
          "setting"
        elsif env_value.present?
          "environment"
        elsif field.default.present?
          "default"
        else
          "blank"
        end

      {
        source: source,
        env_present: env_value.present?
      }
    end

    def provider_settings_attributes
      source = params[:setting].presence || params[:provider_settings].presence
      raise ActionController::ParameterMissing, :setting unless source.respond_to?(:permit)

      source.permit(*registered_provider_fields.keys)
    end

    def registered_provider_fields
      @registered_provider_fields ||= begin
        load_provider_configurations

        Provider::ConfigurationRegistry.all.each_with_object({}) do |configuration, fields|
          configuration.fields.each do |field|
            fields[field.setting_key.to_s] = field
          end
        end
      end
    end

    def load_provider_configurations
      Provider::Factory.ensure_adapters_loaded
    end

    def normalized_setting_value(value)
      normalized = value.to_s.strip
      normalized.empty? ? nil : normalized
    end

    def write_provider_setting(setting_key, value)
      key_string = setting_key.to_s

      if Setting.singleton_class.method_defined?("#{key_string}=")
        Setting.public_send("#{key_string}=", value)
      else
        Setting[setting_key] = value
      end
    end

    def reload_provider_configs(updated_fields)
      updated_provider_keys = Set.new

      updated_fields.each do |field_key|
        Provider::ConfigurationRegistry.all.each do |configuration|
          field = configuration.fields.find { |candidate| candidate.setting_key.to_s == field_key.to_s }
          next unless field

          updated_provider_keys.add(configuration.provider_key)
          break
        end
      end

      updated_provider_keys.each do |provider_key|
        Provider::ConfigurationRegistry.get_adapter_class(provider_key)&.reload_configuration
      end
    end
end
