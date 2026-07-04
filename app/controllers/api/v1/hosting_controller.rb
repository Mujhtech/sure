# frozen_string_literal: true

class Api::V1::HostingController < Api::V1::BaseController
  LLM_BUDGET_MINIMUMS = Settings::HostingsController::LLM_BUDGET_MINIMUMS

  before_action :ensure_self_hosted
  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: %i[update clear_cache disconnect_external_assistant]
  before_action :ensure_admin, only: %i[update clear_cache disconnect_external_assistant]
  before_action :ensure_super_admin_for_onboarding, only: :update

  def show
    render_hosting
  end

  def update
    update_onboarding_settings
    update_brand_fetch_settings
    update_market_data_settings
    update_sync_settings
    update_llm_settings
    update_external_assistant_settings
    update_assistant_type

    render_hosting(message: "Hosting settings updated")
  rescue Setting::ValidationError => error
    render_json({ error: "validation_failed", message: error.message, errors: [ error.message ] }, status: :unprocessable_entity)
  end

  def clear_cache
    DataCacheClearJob.perform_later(current_resource_owner.family)

    render_hosting(message: "Data cache clear queued")
  end

  def disconnect_external_assistant
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil
    Setting.external_assistant_agent_id = nil
    current_resource_owner.family.update!(assistant_type: "builtin") unless ENV["ASSISTANT_TYPE"].present?

    render_hosting(message: "External assistant disconnected")
  rescue StandardError => e
    Rails.logger.error("[External Assistant] API disconnect failed: #{e.message}")
    render_json({ error: "disconnect_failed", message: "External assistant could not be disconnected" }, status: :unprocessable_entity)
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_self_hosted
      return if self_hosted?

      render_json({
        error: "feature_disabled",
        message: "Hosting settings are only available in self-hosted mode"
      }, status: :forbidden)
    end

    def ensure_admin
      return if current_resource_owner&.admin?

      render_json({ error: "forbidden", message: "Hosting settings can only be changed by an admin" }, status: :forbidden)
    end

    def ensure_super_admin_for_onboarding
      onboarding_keys = %i[onboarding_state invite_only_default_family_id]
      return unless onboarding_keys.any? { |key| hosting_params.key?(key) }
      return if current_resource_owner&.super_admin?

      render_json({ error: "forbidden", message: "Onboarding settings can only be changed by a super admin" }, status: :forbidden)
    end

    def render_hosting(message: nil)
      payload = { hosting: hosting_payload, options: hosting_options }
      payload[:message] = message if message.present?

      render_json(payload)
    end

    def hosting_payload
      {
        mode: {
          self_hosted: self_hosted?,
          app_mode: Rails.application.config.app_mode.to_s,
          admin: current_resource_owner.admin?,
          super_admin: current_resource_owner.super_admin?
        },
        onboarding: onboarding_payload,
        brand_fetch: brand_fetch_payload,
        market_data: market_data_payload,
        sync: sync_payload,
        llm: llm_payload,
        assistant: assistant_payload
      }
    end

    def onboarding_payload
      {
        state: Setting.onboarding_state,
        require_email_confirmation: Setting.require_email_confirmation,
        invite_only_default_family_id: Setting.invite_only_default_family_id
      }
    end

    def brand_fetch_payload
      {
        client_id_configured: configured?(Setting.brand_fetch_client_id),
        client_id_env_locked: env_present?("BRAND_FETCH_CLIENT_ID"),
        high_res_logos: Setting.brand_fetch_high_res_logos,
        high_res_logos_env_locked: env_present?("BRAND_FETCH_HIGH_RES_LOGOS"),
        logo_size: Setting.brand_fetch_logo_size
      }
    end

    def market_data_payload
      {
        exchange_rate_provider: ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider,
        exchange_rate_provider_env_locked: env_present?("EXCHANGE_RATE_PROVIDER"),
        securities_providers: Setting.enabled_securities_providers,
        securities_providers_env_locked: env_present?("SECURITIES_PROVIDERS") || env_present?("SECURITIES_PROVIDER"),
        api_keys: {
          twelve_data: credential_status(:twelve_data_api_key, "TWELVE_DATA_API_KEY"),
          tiingo: credential_status(:tiingo_api_key, "TIINGO_API_KEY"),
          eodhd: credential_status(:eodhd_api_key, "EODHD_API_KEY"),
          alpha_vantage: credential_status(:alpha_vantage_api_key, "ALPHA_VANTAGE_API_KEY"),
          tinkoff_invest: credential_status(:tinkoff_invest_api_key, "TINKOFF_INVEST_API_KEY")
        }
      }
    end

    def sync_payload
      {
        include_pending: Setting.syncs_include_pending,
        include_pending_env_locked: env_present?("SIMPLEFIN_INCLUDE_PENDING") || env_present?("PLAID_INCLUDE_PENDING"),
        auto_sync_enabled: Setting.auto_sync_enabled,
        auto_sync_enabled_env_locked: env_present?("AUTO_SYNC_ENABLED"),
        auto_sync_time: Setting.auto_sync_time,
        auto_sync_time_env_locked: env_present?("AUTO_SYNC_TIME"),
        auto_sync_timezone: Setting.auto_sync_timezone
      }
    end

    def llm_payload
      {
        provider: normalized_llm_provider,
        provider_env_locked: env_present?("LLM_PROVIDER"),
        openai: {
          configured: Provider::Openai.configured?,
          access_token_configured: configured?(Setting.openai_access_token),
          access_token_env_locked: env_present?("OPENAI_ACCESS_TOKEN"),
          uri_base: Setting.openai_uri_base,
          uri_base_env_locked: env_present?("OPENAI_URI_BASE"),
          model: Setting.openai_model,
          model_env_locked: env_present?("OPENAI_MODEL"),
          effective_model: Provider::Openai.effective_model,
          json_mode: Setting.openai_json_mode,
          json_mode_env_locked: env_present?("LLM_JSON_MODE")
        },
        anthropic: {
          configured: Provider::Anthropic.configured?,
          access_token_configured: configured?(Setting.anthropic_access_token),
          access_token_env_locked: env_present?("ANTHROPIC_ACCESS_TOKEN") || env_present?("ANTHROPIC_API_KEY"),
          base_url: Setting.anthropic_base_url,
          base_url_env_locked: env_present?("ANTHROPIC_BASE_URL"),
          model: Setting.anthropic_model,
          model_env_locked: env_present?("ANTHROPIC_MODEL"),
          effective_model: Provider::Anthropic.effective_model
        },
        budgets: {
          context_window: budget_payload(:llm_context_window, "LLM_CONTEXT_WINDOW"),
          max_response_tokens: budget_payload(:llm_max_response_tokens, "LLM_MAX_RESPONSE_TOKENS"),
          max_items_per_call: budget_payload(:llm_max_items_per_call, "LLM_MAX_ITEMS_PER_CALL")
        }
      }
    end

    def assistant_payload
      config = Assistant::External.config

      {
        type: effective_assistant_type,
        type_env_locked: env_present?("ASSISTANT_TYPE"),
        external: {
          configured: Assistant::External.configured?,
          available_for_user: Assistant::External.available_for?(current_resource_owner),
          url: config.url,
          url_env_locked: env_present?("EXTERNAL_ASSISTANT_URL"),
          token_configured: configured?(config.token),
          token_env_locked: env_present?("EXTERNAL_ASSISTANT_TOKEN"),
          agent_id: config.agent_id,
          agent_id_env_locked: env_present?("EXTERNAL_ASSISTANT_AGENT_ID")
        }
      }
    end

    def hosting_options
      {
        onboarding_states: Setting::ONBOARDING_STATES,
        llm_providers: %w[openai anthropic],
        assistant_types: Family::ASSISTANT_TYPES,
        exchange_rate_providers: %w[twelve_data yahoo_finance moex_public],
        securities_providers: Security.valid_price_providers,
        openai_json_modes: [ nil, "strict", "none", "json_object", "auto" ],
        llm_budget_minimums: LLM_BUDGET_MINIMUMS
      }
    end

    def update_onboarding_settings
      Setting.onboarding_state = hosting_params[:onboarding_state].to_s if hosting_params.key?(:onboarding_state)
      Setting.require_email_confirmation = boolean_param(hosting_params[:require_email_confirmation]) if hosting_params.key?(:require_email_confirmation)
      Setting.invite_only_default_family_id = hosting_params[:invite_only_default_family_id].presence if hosting_params.key?(:invite_only_default_family_id)
    end

    def update_brand_fetch_settings
      Setting.brand_fetch_client_id = hosting_params[:brand_fetch_client_id] if writable?(:brand_fetch_client_id, "BRAND_FETCH_CLIENT_ID")
      Setting.brand_fetch_high_res_logos = boolean_param(hosting_params[:brand_fetch_high_res_logos]) if writable?(:brand_fetch_high_res_logos, "BRAND_FETCH_HIGH_RES_LOGOS")
    end

    def update_market_data_settings
      update_encrypted_setting(:twelve_data_api_key, "TWELVE_DATA_API_KEY")
      update_encrypted_setting(:tiingo_api_key, "TIINGO_API_KEY")
      update_encrypted_setting(:eodhd_api_key, "EODHD_API_KEY")
      update_encrypted_setting(:alpha_vantage_api_key, "ALPHA_VANTAGE_API_KEY")
      update_encrypted_setting(:tinkoff_invest_api_key, "TINKOFF_INVEST_API_KEY")

      Setting.exchange_rate_provider = hosting_params[:exchange_rate_provider] if writable?(:exchange_rate_provider, "EXCHANGE_RATE_PROVIDER")
      Setting.securities_provider = hosting_params[:securities_provider] if writable?(:securities_provider, "SECURITIES_PROVIDER")

      return unless hosting_params.key?(:securities_providers) && !env_present?("SECURITIES_PROVIDERS") && !env_present?("SECURITIES_PROVIDER")

      new_providers = Array(hosting_params[:securities_providers]).reject(&:blank?) & Security.valid_price_providers
      old_providers = Setting.enabled_securities_providers
      Setting.securities_providers = new_providers.join(",")
      Setting.securities_provider = nil if new_providers.empty?

      mark_removed_security_providers_offline(old_providers - new_providers)
      bring_added_security_providers_online(new_providers - old_providers)
    end

    def update_sync_settings
      if writable?(:syncs_include_pending, nil) && !env_present?("SIMPLEFIN_INCLUDE_PENDING") && !env_present?("PLAID_INCLUDE_PENDING")
        Setting.syncs_include_pending = boolean_param(hosting_params[:syncs_include_pending])
      end

      sync_settings_changed = false

      if writable?(:auto_sync_enabled, "AUTO_SYNC_ENABLED")
        Setting.auto_sync_enabled = boolean_param(hosting_params[:auto_sync_enabled])
        sync_settings_changed = true
      end

      if writable?(:auto_sync_time, "AUTO_SYNC_TIME")
        time_value = hosting_params[:auto_sync_time]
        raise Setting::ValidationError, "Auto sync time must be HH:MM" unless Setting.valid_auto_sync_time?(time_value)

        Setting.auto_sync_time = time_value
        Setting.auto_sync_timezone = current_user_timezone
        sync_settings_changed = true
      end

      sync_auto_sync_scheduler! if sync_settings_changed
    end

    def update_llm_settings
      update_encrypted_setting(:openai_access_token, "OPENAI_ACCESS_TOKEN")

      if hosting_params.key?(:openai_uri_base) || hosting_params.key?(:openai_model)
        Setting.validate_openai_config!(
          uri_base: hosting_params.key?(:openai_uri_base) ? hosting_params[:openai_uri_base] : Setting.openai_uri_base,
          model: hosting_params.key?(:openai_model) ? hosting_params[:openai_model] : Setting.openai_model
        )
      end

      Setting.openai_uri_base = hosting_params[:openai_uri_base] if writable?(:openai_uri_base, "OPENAI_URI_BASE")
      Setting.openai_model = hosting_params[:openai_model] if writable?(:openai_model, "OPENAI_MODEL")
      Setting.openai_json_mode = hosting_params[:openai_json_mode].presence if writable?(:openai_json_mode, "LLM_JSON_MODE")

      update_encrypted_setting(:anthropic_access_token, "ANTHROPIC_ACCESS_TOKEN", alternate_env_key: "ANTHROPIC_API_KEY")
      update_anthropic_base_url if writable?(:anthropic_base_url, "ANTHROPIC_BASE_URL")
      Setting.anthropic_model = hosting_params[:anthropic_model].presence if writable?(:anthropic_model, "ANTHROPIC_MODEL")

      if hosting_params.key?(:llm_provider) && !env_present?("LLM_PROVIDER") && %w[openai anthropic].include?(hosting_params[:llm_provider].to_s)
        Setting.llm_provider = hosting_params[:llm_provider].to_s
      end

      update_llm_budgets
    end

    def update_external_assistant_settings
      Setting.external_assistant_url = hosting_params[:external_assistant_url] if writable?(:external_assistant_url, "EXTERNAL_ASSISTANT_URL")
      update_encrypted_setting(:external_assistant_token, "EXTERNAL_ASSISTANT_TOKEN")
      Setting.external_assistant_agent_id = hosting_params[:external_assistant_agent_id] if writable?(:external_assistant_agent_id, "EXTERNAL_ASSISTANT_AGENT_ID")
    end

    def update_assistant_type
      return unless params[:family].present? && params[:family][:assistant_type].present?
      return if env_present?("ASSISTANT_TYPE")

      assistant_type = params[:family][:assistant_type]
      current_resource_owner.family.update!(assistant_type: assistant_type) if Family::ASSISTANT_TYPES.include?(assistant_type)
    end

    def update_anthropic_base_url
      raw_base_url = hosting_params[:anthropic_base_url].to_s.strip
      if raw_base_url.blank?
        Setting.anthropic_base_url = nil
        return
      end

      parsed = URI.parse(raw_base_url) rescue nil
      raise Setting::ValidationError, "Anthropic Base URL must be an http or https URL" unless parsed.is_a?(URI::HTTP)

      effective_model = hosting_params.key?(:anthropic_model) ? hosting_params[:anthropic_model].to_s.strip : Setting.anthropic_model.to_s.strip
      raise Setting::ValidationError, "Anthropic Model is required when using a custom Base URL" if effective_model.blank?

      Setting.anthropic_base_url = raw_base_url
    end

    def update_llm_budgets
      LLM_BUDGET_MINIMUMS.each do |key, minimum|
        env_key = key.to_s.upcase
        next unless hosting_params.key?(key) && !env_present?(env_key)

        raw = hosting_params[key].to_s.strip
        if raw.blank?
          Setting.public_send("#{key}=", nil)
          next
        end

        parsed = Integer(raw, 10) rescue nil
        raise Setting::ValidationError, "#{key} must be a whole number greater than or equal to #{minimum}" if parsed.nil? || parsed < minimum

        Setting.public_send("#{key}=", parsed)
      end
    end

    def mark_removed_security_providers_offline(providers)
      providers.each do |provider|
        Security.where(price_provider: provider, offline: false)
                .in_batches.update_all(offline: true, offline_reason: "provider_disabled")
      end
    end

    def bring_added_security_providers_online(providers)
      providers.each do |provider|
        Security.where(price_provider: provider, offline: true, offline_reason: "provider_disabled")
                .in_batches.update_all(offline: false, offline_reason: nil, failed_fetch_count: 0, failed_fetch_at: nil)
      end
    end

    def sync_auto_sync_scheduler!
      AutoSyncScheduler.sync!
    rescue StandardError => error
      Rails.logger.error("[AutoSyncScheduler] API scheduler sync failed: #{error.message}")
    end

    def hosting_params
      @hosting_params ||= params.fetch(:setting, ActionController::Parameters.new).permit(
        :onboarding_state,
        :require_email_confirmation,
        :invite_only_default_family_id,
        :brand_fetch_client_id,
        :brand_fetch_high_res_logos,
        :twelve_data_api_key,
        :tiingo_api_key,
        :eodhd_api_key,
        :alpha_vantage_api_key,
        :tinkoff_invest_api_key,
        :openai_access_token,
        :openai_uri_base,
        :openai_model,
        :openai_json_mode,
        :anthropic_access_token,
        :anthropic_base_url,
        :anthropic_model,
        :llm_provider,
        :llm_context_window,
        :llm_max_response_tokens,
        :llm_max_items_per_call,
        :exchange_rate_provider,
        :securities_provider,
        :syncs_include_pending,
        :auto_sync_enabled,
        :auto_sync_time,
        :external_assistant_url,
        :external_assistant_token,
        :external_assistant_agent_id,
        securities_providers: []
      )
    end

    def writable?(param_key, env_key)
      hosting_params.key?(param_key) && (env_key.blank? || !env_present?(env_key))
    end

    def update_encrypted_setting(param_key, env_key, alternate_env_key: nil)
      return unless hosting_params.key?(param_key)
      return if env_present?(env_key) || (alternate_env_key.present? && env_present?(alternate_env_key))

      value = hosting_params[param_key].to_s.strip
      Setting.public_send("#{param_key}=", value) unless value.blank? || value == "********"
    end

    def budget_payload(key, env_key)
      {
        value: Setting.public_send(key),
        minimum: LLM_BUDGET_MINIMUMS.fetch(key),
        env_locked: env_present?(env_key)
      }
    end

    def credential_status(setting_key, env_key)
      {
        configured: configured?(Setting.public_send(setting_key)),
        env_locked: env_present?(env_key)
      }
    end

    def normalized_llm_provider
      Setting.llm_provider.to_s == "anthropic" ? "anthropic" : "openai"
    end

    def effective_assistant_type
      type = ENV["ASSISTANT_TYPE"].presence || current_resource_owner.family.assistant_type
      Family::ASSISTANT_TYPES.include?(type) ? type : "builtin"
    end

    def current_user_timezone
      current_resource_owner.family&.timezone.presence || "UTC"
    end

    def boolean_param(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def configured?(value)
      value.present?
    end

    def env_present?(key)
      ENV[key].present?
    end
end
