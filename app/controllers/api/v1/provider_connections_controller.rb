# frozen_string_literal: true

class Api::V1::ProviderConnectionsController < Api::V1::BaseController
  SYNC_ALL_THROTTLE = 30.seconds
  SNAPTRADE_PERMITTED_OAUTH_SCOPES = %w[read].freeze
  SOPHTRON_CONNECTION_STATUS_POLL_INTERVAL_SECONDS = 4
  SOPHTRON_MAX_SECURITY_ANSWERS = 10
  SOPHTRON_MAX_SECURITY_ANSWER_LENGTH = 256
  SHOWABLE_PLAID_ERROR_CODES = %w[
    INVALID_PRODUCT
    PRODUCTS_NOT_SUPPORTED
    NO_PRODUCTS_PERMISSION
    ADDITION_LIMIT
    INVALID_INSTITUTION
    INSTITUTION_NOT_ENABLED_IN_REGION
    INSTITUTION_NOT_SUPPORTED
  ].freeze
  PROVIDER_CONNECTION_DEFINITIONS = ProviderConnectionStatus::PROVIDERS.index_by { |provider| provider[:key] }.freeze
  PROVIDER_SYNCABLE_TYPES = ProviderConnectionStatus::PROVIDERS.index_by { |provider| provider[:key] }
                                                                .transform_values { |provider| provider[:type] }
                                                                .freeze
  MANAGED_PROVIDER_CONNECTIONS = {
    "akahu" => {
      type: "AkahuItem",
      param_key: :akahu_item,
      fields: %i[name sync_start_date app_token user_token],
      secret_fields: %i[app_token user_token],
      default_name: "Akahu Connection",
      initial_sync: true
    },
    "up" => {
      type: "UpItem",
      param_key: :up_item,
      fields: %i[name sync_start_date access_token],
      secret_fields: %i[access_token],
      default_name: "Up Connection",
      initial_sync: true
    },
    "lunchflow" => {
      type: "LunchflowItem",
      param_key: :lunchflow_item,
      fields: %i[name sync_start_date api_key base_url],
      secret_fields: %i[api_key],
      default_name: "Lunch Flow Connection",
      initial_sync: true,
      nullable_blank_fields: %i[base_url]
    },
    "mercury" => {
      type: "MercuryItem",
      param_key: :mercury_item,
      fields: %i[name sync_start_date token base_url],
      secret_fields: %i[token],
      default_name: "Mercury Connection",
      initial_sync: true,
      nullable_blank_fields: %i[base_url]
    },
    "brex" => {
      type: "BrexItem",
      param_key: :brex_item,
      fields: %i[name sync_start_date token base_url],
      secret_fields: %i[token],
      default_name: "Brex Connection",
      initial_sync: true,
      nullable_blank_fields: %i[base_url]
    },
    "sophtron" => {
      type: "SophtronItem",
      param_key: :sophtron_item,
      fields: %i[name sync_start_date user_id access_key base_url],
      secret_fields: %i[user_id access_key],
      default_name: "Sophtron Connection",
      nullable_blank_fields: %i[base_url]
    },
    "coinbase" => {
      type: "CoinbaseItem",
      param_key: :coinbase_item,
      fields: %i[name sync_start_date api_key api_secret],
      secret_fields: %i[api_key api_secret],
      default_name: "Coinbase Connection",
      after_create: :set_coinbase_institution_defaults!,
      initial_sync: true
    },
    "binance" => {
      type: "BinanceItem",
      param_key: :binance_item,
      fields: %i[name sync_start_date api_key api_secret],
      secret_fields: %i[api_key api_secret],
      default_name: "Binance Connection",
      after_create: :set_binance_institution_defaults!,
      initial_sync: true
    },
    "kraken" => {
      type: "KrakenItem",
      param_key: :kraken_item,
      fields: %i[name sync_start_date api_key api_secret],
      secret_fields: %i[api_key api_secret],
      default_name: "Kraken Connection",
      after_create: :set_kraken_institution_defaults!,
      initial_sync: true
    },
    "ibkr" => {
      type: "IbkrItem",
      param_key: :ibkr_item,
      fields: %i[name query_id token],
      secret_fields: %i[query_id token],
      default_name: "Interactive Brokers Connection",
      initial_sync: true
    },
    "indexa_capital" => {
      type: "IndexaCapitalItem",
      param_key: :indexa_capital_item,
      fields: %i[name sync_start_date api_token username document password],
      secret_fields: %i[api_token username document password],
      default_name: "Indexa Capital Connection"
    },
    "enable_banking" => {
      type: "EnableBankingItem",
      param_key: :enable_banking_item,
      fields: %i[name country_code application_id client_certificate],
      secret_fields: %i[client_certificate],
      default_name: "Enable Banking Connection"
    }
  }.freeze

  before_action :ensure_read_scope, only: %i[index provider_accounts coinstats_options enable_banking_banks sophtron_institutions]
  before_action :ensure_write_scope, only: %i[create update sync_all sync sync_connection dismiss_replacement_suggestion destroy link_provider_account plaid_link_token plaid_update_link_token snaptrade_start_oauth_device_flow snaptrade_complete_oauth_device_flow coinstats_link_wallet coinstats_link_exchange enable_banking_start_authorization enable_banking_complete_authorization sophtron_connect_institution sophtron_connection_status sophtron_submit_mfa sophtron_toggle_manual_sync]
  before_action :ensure_admin, only: %i[create update sync_all sync sync_connection dismiss_replacement_suggestion destroy provider_accounts link_provider_account plaid_link_token plaid_update_link_token snaptrade_start_oauth_device_flow snaptrade_complete_oauth_device_flow coinstats_options coinstats_link_wallet coinstats_link_exchange enable_banking_banks enable_banking_start_authorization enable_banking_complete_authorization sophtron_institutions sophtron_connect_institution sophtron_connection_status sophtron_submit_mfa sophtron_toggle_manual_sync]

  def index
    @provider_connections = ProviderConnectionStatus.for_family(current_resource_owner.family)
    render :index
  rescue StandardError => e
    Rails.logger.error "ProviderConnectionsController#index error: #{e.message}"
    e.backtrace&.each { |line| Rails.logger.error line }

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def sync_all
    family = current_resource_owner.family
    now = Time.current

    updated_count = Family
      .where(id: family.id)
      .where("last_sync_all_attempted_at IS NULL OR last_sync_all_attempted_at <= ?", SYNC_ALL_THROTTLE.ago)
      .update_all(last_sync_all_attempted_at: now, updated_at: now)

    if updated_count.zero?
      retry_after = sync_all_retry_after_seconds(family)
      response.headers["Retry-After"] = retry_after.to_s

      return render_provider_sync_response(
        message: "Sync all was requested recently",
        sync: sync_metadata(
          provider: nil,
          status: "throttled",
          scheduled: false,
          retry_after_seconds: retry_after
        )
      )
    end

    SyncAllProvidersJob.perform_later(family.id)

    render_provider_sync_response(
      message: "Syncing all connected providers",
      sync: sync_metadata(provider: nil, status: "scheduled", scheduled: true),
      status: :accepted
    )
  rescue StandardError => e
    log_provider_connection_error(:sync_all, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def create
    provider_key = params[:provider_key].to_s
    return create_plaid_connection if provider_key == "plaid"
    return create_simplefin_connection if provider_key == "simplefin"
    return create_coinstats_connection if provider_key == "coinstats"
    return create_sophtron_connection if provider_key == "sophtron"

    config = managed_provider_config(provider_key)
    return render_unsupported_provider(provider_key, action: "creation") unless config

    item = build_provider_connection(config)
    sync_scheduled = false

    ActiveRecord::Base.transaction do
      item.save!
      run_provider_after_create_hook(item, config)
      sync_scheduled = schedule_initial_provider_sync(item, config)
    end

    render_provider_mutation_response(
      item: item,
      provider_key: provider_key,
      message: "Provider connection created",
      sync: provider_mutation_sync_metadata(scheduled: sync_scheduled),
      status: :created
    )
  rescue ActiveRecord::RecordInvalid => e
    render_provider_validation_error(e.record)
  rescue Plaid::ApiError => e
    render_plaid_api_error(e)
  rescue ActionController::ParameterMissing => e
    handle_bad_request(e)
  rescue StandardError => e
    log_provider_connection_error(:create, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def update
    provider_key = params[:provider_key].to_s
    return update_simplefin_connection if provider_key == "simplefin"
    return update_coinstats_connection if provider_key == "coinstats"
    return update_sophtron_connection if provider_key == "sophtron"

    config = managed_provider_config(provider_key)
    return render_unsupported_provider(provider_key, action: "updates") unless config

    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

    item = provider_model(config).where(family: current_resource_owner.family).find(params[:id])
    attributes = provider_connection_attributes(config, persisted: true)

    ActiveRecord::Base.transaction do
      item.update!(attributes)
    end

    render_provider_mutation_response(
      item: item,
      provider_key: provider_key,
      message: "Provider connection updated",
      sync: provider_mutation_sync_metadata(scheduled: false),
      status: :ok
    )
  rescue ActiveRecord::RecordInvalid => e
    render_provider_validation_error(e.record)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue ActionController::ParameterMissing => e
    handle_bad_request(e)
  rescue StandardError => e
    log_provider_connection_error(:update, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def plaid_link_token
    attributes = plaid_connection_attributes
    region = normalized_plaid_region(attributes[:region])
    link_token = current_resource_owner.family.get_link_token(
      webhooks_url: plaid_webhooks_url(region),
      redirect_url: plaid_redirect_url(attributes),
      accountable_type: plaid_accountable_type(attributes),
      region: region
    )

    return render_plaid_not_configured(region) if link_token.blank?

    render_json({
      provider: "plaid",
      mode: "create",
      region: region.to_s,
      link_token: link_token
    }, status: :created)
  rescue Plaid::ApiError => e
    render_plaid_api_error(e)
  rescue ActionController::ParameterMissing => e
    handle_bad_request(e)
  rescue StandardError => e
    log_provider_connection_error(:plaid_link_token, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def plaid_update_link_token
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

    item = PlaidItem.where(family: current_resource_owner.family).find(params[:id])
    region = item.plaid_region.to_sym
    attributes = plaid_connection_attributes(required: false)
    link_token = item.get_update_link_token(
      webhooks_url: plaid_webhooks_url(region),
      redirect_url: plaid_redirect_url(attributes)
    )

    if link_token.blank?
      return render_json({
        error: "provider_requires_update",
        message: "Plaid connection could not create an update link token"
      }, status: :unprocessable_entity)
    end

    render_json({
      provider: "plaid",
      mode: "update",
      region: region.to_s,
      provider_connection_id: item.id,
      link_token: link_token
    })
  rescue Plaid::ApiError => e
    render_plaid_api_error(e)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    log_provider_connection_error(:plaid_update_link_token, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def snaptrade_start_oauth_device_flow
    unless Provider::Snaptrade.oauth_client_id_configured?
      return render_snaptrade_oauth_not_configured
    end

    item = snaptrade_oauth_item
    authorization = item.start_oauth_device_flow(scope: snaptrade_oauth_scope)

    render_json({
      provider: "snaptrade",
      provider_connection: provider_connection_status_for_item(item, "snaptrade"),
      device_authorization: snaptrade_device_authorization_payload(authorization)
    }, status: :created)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue ActiveRecord::RecordInvalid => e
    render_provider_validation_error(e.record)
  rescue ActiveRecord::Encryption::Errors::Base => e
    Rails.logger.error "ProviderConnectionsController#snaptrade_start_oauth_device_flow decryption error: #{e.class} - #{e.message}"
    render_snaptrade_oauth_error("Unable to read SnapTrade credentials")
  rescue Provider::Snaptrade::Error => e
    Rails.logger.error "ProviderConnectionsController#snaptrade_start_oauth_device_flow error: #{e.class} - #{e.message}"
    render_snaptrade_oauth_error("Unable to start SnapTrade OAuth device authorization. Please try again.")
  rescue StandardError => e
    log_provider_connection_error(:snaptrade_start_oauth_device_flow, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def snaptrade_complete_oauth_device_flow
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

    item = SnaptradeItem.where(family: current_resource_owner.family).find(params[:id])
    device_code = snaptrade_device_code
    return render_validation_error("device_code is required") if device_code.blank?

    token_response = item.complete_oauth_device_flow!(device_code: device_code)
    setup = prepare_snaptrade_oauth_account_setup(item)

    render_json({
      provider: "snaptrade",
      provider_connection: provider_connection_status_for_item(item.reload, "snaptrade"),
      oauth: snaptrade_oauth_token_payload(token_response, item),
      account_setup: setup
    })
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::Snaptrade::ApiError => e
    render_json(snaptrade_oauth_error_payload(e), status: e.status_code || :unprocessable_entity)
  rescue Provider::Snaptrade::Error, ActiveRecord::ActiveRecordError, ActiveRecord::Encryption::Errors::Base => e
    Rails.logger.error "ProviderConnectionsController#snaptrade_complete_oauth_device_flow error: #{e.class} - #{e.message}"
    render_snaptrade_oauth_error("Unable to complete SnapTrade OAuth device authorization. Please try again.")
  rescue StandardError => e
    log_provider_connection_error(:snaptrade_complete_oauth_device_flow, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def provider_accounts
    provider_key = params[:provider_key].to_s
    provider_definition = provider_definition_for(provider_key)
    return render_provider_not_found(action: "account setup") unless provider_definition

    item = provider_connection_item(provider_definition)
    records = provider_account_relation(item, provider_definition).to_a
    records = records.reject { |provider_account| provider_account_linked?(provider_account) } if truthy_param?(params[:unlinked_only])

    render_provider_accounts_response(
      item: item,
      provider_definition: provider_definition,
      provider_accounts: records
    )
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    log_provider_connection_error(:provider_accounts, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def coinstats_options
    item = coinstats_item
    provider = Provider::Coinstats.new(item.api_key)

    render_json({
      provider: "coinstats",
      provider_connection: provider_connection_status_for_item(item, "coinstats"),
      blockchains: provider.blockchain_options.map { |label, value| { label: label, value: value } },
      exchanges: provider.exchange_options
    })
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::Coinstats::Error => e
    render_coinstats_api_error(e)
  rescue StandardError => e
    log_provider_connection_error(:coinstats_options, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def coinstats_link_wallet
    item = coinstats_item
    attributes = coinstats_wallet_attributes
    address = attributes[:address].to_s.strip
    blockchain = attributes[:blockchain].to_s.strip
    return render_validation_error("address is required") if address.blank?
    return render_validation_error("blockchain is required") if blockchain.blank?

    result = CoinstatsItem::WalletLinker.new(item, address: address, blockchain: blockchain).link
    return render_coinstats_link_error("CoinStats wallet could not be linked", result.errors) unless result.success?

    render_json({
      message: "CoinStats wallet linked",
      provider_connection: provider_connection_status_for_item(item.reload, "coinstats"),
      wallet: {
        address: address,
        blockchain: blockchain,
        created_count: result.created_count
      },
      data: ProviderConnectionStatus.for_family(current_resource_owner.family)
    }, status: :created)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::Coinstats::Error => e
    render_coinstats_api_error(e)
  rescue StandardError => e
    log_provider_connection_error(:coinstats_link_wallet, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def coinstats_link_exchange
    item = coinstats_item
    attributes = coinstats_exchange_attributes
    connection_id = attributes[:connection_id].to_s.strip
    return render_validation_error("connection_id is required") if connection_id.blank?

    exchange = coinstats_exchange_option(item, connection_id)
    return render_validation_error("Exchange connection is not supported") unless exchange

    connection_fields = coinstats_permitted_exchange_fields(exchange, attributes[:connection_fields])
    return render_validation_error("connection_fields are required") if connection_fields.blank?

    connection_name = attributes[:name].presence || exchange[:name].presence || connection_id.to_s.titleize
    result = CoinstatsItem::ExchangeLinker.new(
      item,
      connection_id: connection_id,
      connection_fields: connection_fields,
      name: connection_name
    ).link
    return render_coinstats_link_error("CoinStats exchange could not be linked", result.errors) unless result.success?

    render_json({
      message: "CoinStats exchange linked",
      provider_connection: provider_connection_status_for_item(item.reload, "coinstats"),
      exchange: {
        connection_id: connection_id,
        name: connection_name,
        created_count: result.created_count
      },
      data: ProviderConnectionStatus.for_family(current_resource_owner.family)
    }, status: :created)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::Coinstats::Error => e
    render_coinstats_api_error(e)
  rescue StandardError => e
    log_provider_connection_error(:coinstats_link_exchange, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def enable_banking_banks
    item = enable_banking_item
    return render_validation_error("Enable Banking credentials are not configured") unless item.credentials_configured?

    country = params[:country].presence || item.country_code
    response = item.enable_banking_provider.get_aspsps(country: country)
    banks = Array(response[:aspsps] || response["aspsps"]).map { |aspsp| enable_banking_bank_payload(aspsp) }
                                                          .sort_by { |aspsp| [ aspsp[:beta] ? 1 : 0, aspsp[:name].to_s.downcase ] }

    render_json({
      provider: "enable_banking",
      provider_connection: provider_connection_status_for_item(item, "enable_banking"),
      country: country,
      banks: banks
    })
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::EnableBanking::EnableBankingError => e
    render_enable_banking_api_error(e)
  rescue StandardError => e
    log_provider_connection_error(:enable_banking_banks, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def enable_banking_start_authorization
    item = enable_banking_item
    return render_validation_error("Enable Banking credentials are not configured") unless item.credentials_configured?

    attributes = enable_banking_authorization_attributes
    aspsp_name = attributes[:aspsp_name].to_s.strip
    return render_validation_error("aspsp_name is required") if aspsp_name.blank?

    target_item = enable_banking_authorization_item(item, attributes)
    target_item.update!(last_psu_ip: request.remote_ip) if request.remote_ip.present?

    redirect_url = target_item.begin_authorization!(
      aspsp_name: aspsp_name,
      redirect_url: attributes[:redirect_url].presence || enable_banking_callback_url,
      state: target_item.id,
      psu_type: attributes[:psu_type].presence || "personal",
      language: attributes[:language].presence || I18n.locale.to_s.split("-").first
    )

    render_json({
      provider: "enable_banking",
      provider_connection: provider_connection_status_for_item(target_item.reload, "enable_banking"),
      authorization: {
        redirect_url: redirect_url,
        state: target_item.id,
        aspsp_name: target_item.aspsp_name,
        psu_type: target_item.psu_type,
        authorization_id: target_item.authorization_id
      }
    }, status: :created)
  rescue ActiveRecord::RecordInvalid => e
    render_provider_validation_error(e.record)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::EnableBanking::EnableBankingError => e
    render_enable_banking_api_error(e)
  rescue StandardError => e
    log_provider_connection_error(:enable_banking_start_authorization, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def enable_banking_complete_authorization
    item = enable_banking_item
    attributes = enable_banking_authorization_completion_attributes
    code = attributes[:code].to_s.strip
    return render_validation_error("code is required") if code.blank?
    return render_validation_error("state does not match provider connection") if attributes[:state].present? && attributes[:state].to_s != item.id

    result = item.complete_authorization(code: code)
    scheduled = schedule_provider_connection_sync(item.reload)

    render_json({
      message: "Enable Banking authorization completed",
      provider: "enable_banking",
      provider_connection: provider_connection_status_for_item(item.reload, "enable_banking"),
      authorization: {
        completed: true,
        session_id_present: item.session_id.present?,
        session_expires_at: item.session_expires_at&.iso8601,
        imported_accounts_count: Array(result[:accounts] || result["accounts"]).size
      },
      sync: provider_mutation_sync_metadata(scheduled: scheduled)
    })
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::EnableBanking::EnableBankingError => e
    render_enable_banking_api_error(e)
  rescue StandardError => e
    log_provider_connection_error(:enable_banking_complete_authorization, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def sophtron_institutions
    item = sophtron_item
    return render_validation_error("Sophtron credentials are not configured") unless item.credentials_configured?

    query = sophtron_institution_query
    return render_validation_error("query must be at least 2 characters") if query.length < 2

    institutions = sophtron_response_data!(item.sophtron_provider.search_institutions(query))

    render_json({
      provider: "sophtron",
      provider_connection: provider_connection_status_for_item(item, "sophtron"),
      query: query,
      institutions: Array(institutions).map { |institution| sophtron_institution_payload(institution) }
    })
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::Sophtron::Error => e
    render_sophtron_api_error(e)
  rescue StandardError => e
    log_provider_connection_error(:sophtron_institutions, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def sophtron_connect_institution
    item = sophtron_item
    return render_validation_error("Sophtron credentials are not configured") unless item.credentials_configured?

    attributes = sophtron_institution_connection_attributes
    return render_validation_error("institution_id is required") if attributes[:institution_id].blank?
    return render_validation_error("bank_username is required") if attributes[:bank_username].blank?
    return render_validation_error("bank_password is required") if attributes[:bank_password].blank?

    target_item = sophtron_institution_connection_item(item, attributes)
    target_item.ensure_customer!
    response = sophtron_response_data!(
      target_item.sophtron_provider.create_user_institution(
        institution_id: attributes[:institution_id],
        username: attributes[:bank_username],
        password: attributes[:bank_password],
        pin: attributes[:bank_pin].to_s
      )
    ).with_indifferent_access

    job_id = response[:JobID] || response[:job_id]
    user_institution_id = response[:UserInstitutionID] || response[:user_institution_id]

    if job_id.blank? || user_institution_id.blank?
      raise Provider::Sophtron::Error.new("Sophtron did not return JobID and UserInstitutionID", :invalid_response)
    end

    target_item.update!(
      name: target_item.name.presence || "Sophtron Connection",
      institution_id: attributes[:institution_id],
      institution_name: attributes[:institution_name],
      user_institution_id: user_institution_id,
      current_job_id: job_id,
      raw_job_payload: response,
      job_status: nil,
      last_connection_error: nil,
      status: :good
    )

    render_json({
      provider: "sophtron",
      provider_connection: provider_connection_status_for_item(target_item.reload, "sophtron"),
      connection: sophtron_connection_payload(
        target_item,
        status: "pending",
        job_id: job_id,
        user_institution_id: user_institution_id
      )
    }, status: :created)
  rescue ActiveRecord::RecordInvalid => e
    render_provider_validation_error(e.record)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::Sophtron::Error => e
    render_sophtron_api_error(e)
  rescue StandardError => e
    log_provider_connection_error(:sophtron_connect_institution, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def sophtron_connection_status
    item = sophtron_item

    if item.current_job_id.blank?
      return render_json({
        provider: "sophtron",
        provider_connection: provider_connection_status_for_item(item, "sophtron"),
        connection: sophtron_connection_payload(
          item,
          status: item.connected_to_institution? ? "connected" : "idle"
        )
      })
    end

    job = sophtron_response_data!(item.sophtron_provider.get_job_information(item.current_job_id)).with_indifferent_access
    item.upsert_job_snapshot!(job)

    if Provider::Sophtron.job_success?(job)
      item.update!(
        current_job_id: nil,
        last_connection_error: nil,
        pending_account_setup: true,
        status: :good
      )
      item.fetch_remote_accounts(force: true)

      render_json({
        provider: "sophtron",
        provider_connection: provider_connection_status_for_item(item.reload, "sophtron"),
        connection: sophtron_connection_payload(item, status: "accounts_ready"),
        account_setup: sophtron_account_setup_payload(item)
      })
    elsif Provider::Sophtron.job_requires_input?(job)
      render_json({
        provider: "sophtron",
        provider_connection: provider_connection_status_for_item(item.reload, "sophtron"),
        connection: sophtron_connection_payload(item, status: "mfa_required", job: job),
        mfa_challenge: sophtron_mfa_challenge_payload(item.build_mfa_challenge(job))
      })
    elsif Provider::Sophtron.job_failed?(job)
      failure_message = sophtron_connection_failure_message(job)
      item.update!(
        current_job_id: nil,
        current_job_sophtron_account_id: nil,
        user_institution_id: nil,
        last_connection_error: failure_message,
        status: :requires_update
      )

      render_json({
        provider: "sophtron",
        provider_connection: provider_connection_status_for_item(item.reload, "sophtron"),
        connection: sophtron_connection_payload(item, status: "failed", job: job, error_message: failure_message)
      })
    elsif Provider::Sophtron.job_completed?(job)
      accounts = begin
        item.fetch_remote_accounts(force: true)
      rescue Provider::Sophtron::Error => e
        Rails.logger.info("Sophtron accounts are not available after completed job #{item.current_job_id}: #{e.message}")
        []
      end

      if accounts.any?
        item.update!(
          current_job_id: nil,
          last_connection_error: nil,
          pending_account_setup: true,
          status: :good
        )

        render_json({
          provider: "sophtron",
          provider_connection: provider_connection_status_for_item(item.reload, "sophtron"),
          connection: sophtron_connection_payload(item, status: "accounts_ready", job: job),
          account_setup: sophtron_account_setup_payload(item)
        })
      else
        render_json({
          provider: "sophtron",
          provider_connection: provider_connection_status_for_item(item.reload, "sophtron"),
          connection: sophtron_connection_payload(item, status: "completed", job: job)
        })
      end
    else
      render_json({
        provider: "sophtron",
        provider_connection: provider_connection_status_for_item(item.reload, "sophtron"),
        connection: sophtron_connection_payload(item, status: "pending", job: job)
      })
    end
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::Sophtron::Error => e
    render_sophtron_api_error(e)
  rescue StandardError => e
    log_provider_connection_error(:sophtron_connection_status, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def sophtron_submit_mfa
    item = sophtron_item
    return render_validation_error("Sophtron connection is not waiting for MFA") if item.current_job_id.blank?

    attributes = sophtron_mfa_attributes
    mfa_type = attributes[:mfa_type].to_s
    provider = item.sophtron_provider

    case mfa_type
    when "security_answer"
      security_answers = sophtron_security_answers(attributes)
      return render_validation_error("security_answers are required") if security_answers.blank?

      sophtron_response_data!(provider.update_job_security_answer(item.current_job_id, security_answers))
    when "token_choice"
      return render_validation_error("token_choice is required") if attributes[:token_choice].blank?

      sophtron_response_data!(provider.update_job_token_input(item.current_job_id, token_choice: attributes[:token_choice]))
    when "token_input"
      return render_validation_error("token_input is required") if attributes[:token_input].blank?

      sophtron_response_data!(provider.update_job_token_input(item.current_job_id, token_input: attributes[:token_input]))
    when "verify_phone"
      sophtron_response_data!(provider.update_job_token_input(item.current_job_id, verify_phone_flag: true))
    when "captcha"
      return render_validation_error("captcha_input is required") if attributes[:captcha_input].blank?

      sophtron_response_data!(provider.update_job_captcha(item.current_job_id, attributes[:captcha_input]))
    else
      return render_validation_error("mfa_type must be one of: security_answer, token_choice, token_input, verify_phone, captcha")
    end

    render_json({
      message: "Sophtron MFA submitted",
      provider: "sophtron",
      provider_connection: provider_connection_status_for_item(item.reload, "sophtron"),
      connection: sophtron_connection_payload(item, status: "mfa_submitted")
    })
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Provider::Sophtron::Error => e
    render_sophtron_api_error(e)
  rescue StandardError => e
    log_provider_connection_error(:sophtron_submit_mfa, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def sophtron_toggle_manual_sync
    item = sophtron_item
    attributes = sophtron_manual_sync_attributes
    target_accounts = sophtron_manual_sync_target_accounts(item, attributes)
    requested_enabled = manual_sync_requested_enabled(attributes)
    scoped = sophtron_manual_sync_scoped?(attributes)

    if scoped && target_accounts.exists?
      if item.manual_sync? && requested_enabled == false
        item.sophtron_accounts.where.not(id: target_accounts.select(:id)).update_all(manual_sync: true, updated_at: Time.current)
      end

      enabled = requested_enabled.nil? ? !target_accounts.requires_manual_sync.exists? : requested_enabled
      target_accounts.update_all(manual_sync: enabled, updated_at: Time.current)
      item.update!(manual_sync: false) unless enabled
    elsif scoped
      return render_validation_error("No linked Sophtron accounts found for this institution")
    elsif requested_enabled.nil? && target_accounts.exists?
      enabled = !target_accounts.requires_manual_sync.exists?
      target_accounts.update_all(manual_sync: enabled, updated_at: Time.current)
      item.update!(manual_sync: false) unless enabled
    else
      enabled = requested_enabled.nil? ? !item.manual_sync? : requested_enabled
      item.update!(manual_sync: enabled)
      item.sophtron_accounts.update_all(manual_sync: false, updated_at: Time.current) unless enabled
    end

    item.reload
    render_json({
      message: "Sophtron manual sync #{enabled ? 'enabled' : 'disabled'}",
      provider: "sophtron",
      provider_connection: provider_connection_status_for_item(item, "sophtron"),
      manual_sync: sophtron_manual_sync_payload(item, target_accounts, enabled, scoped: scoped)
    })
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    log_provider_connection_error(:sophtron_toggle_manual_sync, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def link_provider_account
    provider_key = params[:provider_key].to_s
    provider_definition = provider_definition_for(provider_key)
    return render_provider_not_found(action: "account setup") unless provider_definition

    item = provider_connection_item(provider_definition)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:provider_account_id])

    provider_account = provider_account_relation(item, provider_definition).find(params[:provider_account_id])
    attributes = provider_account_setup_attributes

    if attributes[:action].to_s == "skip"
      return skip_provider_account_setup(item: item, provider_definition: provider_definition, provider_account: provider_account)
    end

    if provider_account_linked?(provider_account)
      return render_provider_account_conflict("Provider account is already linked")
    end

    account = nil
    setup_action = nil
    sync_scheduled = false

    ActiveRecord::Base.transaction do
      account = if attributes[:account_id].present?
        setup_action = "linked_existing"
        find_linkable_account!(attributes[:account_id], provider_definition)
      else
        setup_action = "created_account"
        create_account_from_provider_account!(provider_account, provider_definition, attributes)
      end

      ensure_provider_account_link!(provider_account, account)
      sync_scheduled = schedule_provider_connection_sync(item)
    end

    provider_account.reload
    account.reload

    render_provider_account_setup_response(
      item: item,
      provider_definition: provider_definition,
      provider_account: provider_account,
      account: account,
      message: setup_action == "created_account" ? "Provider account linked to a new account" : "Provider account linked",
      sync_scheduled: sync_scheduled,
      status: setup_action == "created_account" ? :created : :ok
    )
  rescue ActiveRecord::RecordInvalid => e
    render_provider_account_validation_error(e.record)
  rescue InvalidFilterError => e
    render_validation_error(e.message)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue ActionController::ParameterMissing => e
    handle_bad_request(e)
  rescue StandardError => e
    log_provider_connection_error(:link_provider_account, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def sync
    provider_key = params[:provider_key].to_s
    syncable_type = PROVIDER_SYNCABLE_TYPES[provider_key]

    unless syncable_type
      return render_json({
        error: "provider_not_found",
        message: "Provider is not supported for sync"
      }, status: :not_found)
    end

    items = syncable_type.constantize.where(family: current_resource_owner.family).syncable.to_a
    scheduled_items = items.reject(&:syncing?)
    scheduled_items.each(&:sync_later)

    render_provider_sync_response(
      message: provider_sync_message(provider_key, items, scheduled_items),
      sync: sync_metadata(
        provider: provider_key,
        status: provider_sync_status(items, scheduled_items),
        scheduled: scheduled_items.any?,
        total_count: items.count,
        scheduled_count: scheduled_items.count,
        skipped_count: items.count - scheduled_items.count
      ),
      status: scheduled_items.any? ? :accepted : :ok
    )
  rescue StandardError => e
    log_provider_connection_error(:sync, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def sync_connection
    provider_key = params[:provider_key].to_s
    syncable_type = PROVIDER_SYNCABLE_TYPES[provider_key]

    unless syncable_type
      return render_json({
        error: "provider_not_found",
        message: "Provider is not supported for sync"
      }, status: :not_found)
    end

    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

    item = syncable_type.constantize.where(family: current_resource_owner.family).find(params[:id])
    mode = provider_connection_sync_mode

    if mode == "balances_only" && provider_key != "simplefin"
      return render_validation_error("balances_only sync is only supported for SimpleFIN connections")
    end

    scheduled = schedule_provider_connection_sync(item, mode: mode)
    status = scheduled ? :accepted : :ok

    render_provider_sync_response(
      message: provider_connection_sync_message(provider_key, scheduled, mode: mode),
      sync: sync_metadata(
        provider: provider_key,
        provider_connection_id: item.id,
        mode: mode,
        status: scheduled ? "scheduled" : "already_syncing",
        scheduled: scheduled,
        total_count: 1,
        scheduled_count: scheduled ? 1 : 0,
        skipped_count: scheduled ? 0 : 1
      ),
      status: status
    )
  rescue ActiveRecord::RecordNotFound
    raise
  rescue InvalidFilterError => e
    render_validation_error(e.message)
  rescue StandardError => e
    log_provider_connection_error(:sync_connection, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def dismiss_replacement_suggestion
    provider_key = params[:provider_key].to_s
    unless provider_key == "simplefin"
      return render_json({
        error: "provider_not_supported",
        message: "Replacement suggestion dismissal is only supported for SimpleFIN connections"
      }, status: :not_found)
    end

    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

    item = SimplefinItem.where(family: current_resource_owner.family).find(params[:id])
    attributes = replacement_suggestion_attributes
    dormant_sfa_id = attributes[:dormant_sfa_id].to_s
    active_sfa_id = attributes[:active_sfa_id].to_s

    unless simplefin_account_ids_belong_to_item?(item, dormant_sfa_id, active_sfa_id)
      return render_validation_error("dormant_sfa_id and active_sfa_id must belong to this SimpleFIN connection")
    end

    dismissal_key = "#{dormant_sfa_id}:#{active_sfa_id}"
    sync = item.syncs.order(created_at: :desc).first
    dismissed_suggestions = []

    if sync
      stats = sync.sync_stats.is_a?(Hash) ? sync.sync_stats.deep_dup : {}
      dismissed_suggestions = Array(stats["dismissed_replacement_suggestions"])
      dismissed_suggestions = (dismissed_suggestions + [ dismissal_key ]).uniq
      stats["dismissed_replacement_suggestions"] = dismissed_suggestions
      sync.update!(sync_stats: stats)
    end

    render_json({
      message: "Replacement suggestion dismissed",
      provider_connection: provider_connection_status_for_item(item, "simplefin"),
      replacement_suggestion: {
        dormant_sfa_id: dormant_sfa_id,
        active_sfa_id: active_sfa_id,
        dismissal_key: dismissal_key,
        dismissed: true,
        persisted: sync.present?
      },
      dismissed_replacement_suggestions: dismissed_suggestions
    }, status: :ok)
  rescue ActiveRecord::RecordNotFound
    raise
  rescue ActionController::ParameterMissing => e
    handle_bad_request(e)
  rescue StandardError => e
    log_provider_connection_error(:dismiss_replacement_suggestion, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  def destroy
    provider_key = params[:provider_key].to_s
    syncable_type = PROVIDER_SYNCABLE_TYPES[provider_key]

    unless syncable_type
      return render_json({
        error: "provider_not_found",
        message: "Provider is not supported for deletion"
      }, status: :not_found)
    end

    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

    item = syncable_type.constantize.where(family: current_resource_owner.family).find(params[:id])

    if item.respond_to?(:scheduled_for_deletion?) && item.scheduled_for_deletion?
      return render_provider_destroy_response(
        item: item,
        provider_key: provider_key,
        message: "Provider connection is already scheduled for deletion",
        status: :ok
      )
    end

    ActiveRecord::Base.transaction do
      item.unlink_all!(dry_run: false) if item.respond_to?(:unlink_all!)
      item.destroy_later
    end

    render_provider_destroy_response(
      item: item,
      provider_key: provider_key,
      message: "Provider connection scheduled for deletion",
      status: :accepted
    )
  rescue ActiveRecord::RecordNotFound
    raise
  rescue StandardError => e
    log_provider_connection_error(:destroy, e)

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_admin
      return if current_resource_owner.admin?

      render_json({
        error: "forbidden",
        message: "Provider connections require a family admin"
      }, status: :forbidden)
    end

    def render_provider_sync_response(message:, sync:, status: :ok)
      render_json({
        message: message,
        sync: sync,
        data: ProviderConnectionStatus.for_family(current_resource_owner.family)
      }, status: status)
    end

    def render_provider_mutation_response(item:, provider_key:, message:, sync:, status:)
      data = ProviderConnectionStatus.for_family(current_resource_owner.family)

      render_json({
        message: message,
        provider_connection: data.detect { |connection| connection[:id] == item.id && connection[:provider] == provider_key },
        sync: sync,
        data: data
      }, status: status)
    end

    def render_provider_accounts_response(item:, provider_definition:, provider_accounts:)
      render_json({
        provider_connection: provider_connection_status_for_item(item, provider_definition[:key]),
        supported_account_types: supported_account_types_for(provider_definition),
        data: provider_accounts.map { |provider_account| provider_account_payload(provider_account, provider_definition) },
        meta: provider_accounts_meta(provider_accounts, unlinked_only: truthy_param?(params[:unlinked_only]))
      })
    end

    def render_provider_account_setup_response(item:, provider_definition:, provider_account:, account:, message:, sync_scheduled:, status:)
      render_json({
        message: message,
        provider_connection: provider_connection_status_for_item(item, provider_definition[:key]),
        provider_account: provider_account_payload(provider_account, provider_definition),
        account: account_payload(account),
        sync: provider_account_setup_sync_metadata(sync_scheduled)
      }, status: status)
    end

    def render_provider_destroy_response(item:, provider_key:, message:, status:)
      render_json({
        message: message,
        provider_connection: {
          id: item.id,
          provider: provider_key,
          provider_type: item.class.name,
          scheduled_for_deletion: item.respond_to?(:scheduled_for_deletion?) ? item.scheduled_for_deletion? : true
        },
        data: ProviderConnectionStatus.for_family(current_resource_owner.family)
      }, status: status)
    end

    def render_provider_account_validation_error(record)
      render_json({
        error: "validation_failed",
        message: "Provider account could not be linked",
        errors: record.errors.full_messages
      }, status: :unprocessable_entity)
    end

    def render_provider_account_conflict(message)
      render_json({
        error: "provider_account_conflict",
        message: message
      }, status: :conflict)
    end

    def render_plaid_not_configured(region)
      render_json({
        error: "provider_not_configured",
        message: "Plaid #{region.to_s.upcase} is not configured for this family"
      }, status: :unprocessable_entity)
    end

    def render_plaid_api_error(error)
      payload = safe_parse_plaid_error(error)
      provider_code = payload["error_code"].presence
      provider_message = payload["error_message"].presence
      message = if provider_code.in?(SHOWABLE_PLAID_ERROR_CODES) && provider_message.present?
        provider_message
      else
        "Plaid request failed"
      end

      render_json({
        error: "plaid_request_failed",
        message: message,
        details: {
          provider_code: provider_code
        }.compact
      }, status: :bad_gateway)
    end

    def render_simplefin_api_error(error)
      message = if error.respond_to?(:error_type) && error.error_type == :token_compromised
        "SimpleFIN setup token is no longer valid"
      else
        "SimpleFIN setup token could not be claimed"
      end

      render_json({
        error: "simplefin_request_failed",
        message: message
      }, status: :bad_gateway)
    end

    def render_coinstats_api_error(error)
      render_json({
        error: "coinstats_request_failed",
        message: error.message.presence || "CoinStats request failed"
      }, status: :bad_gateway)
    end

    def render_enable_banking_api_error(error)
      render_json({
        error: "enable_banking_request_failed",
        message: error.message.presence || "Enable Banking request failed"
      }, status: :bad_gateway)
    end

    def render_sophtron_api_error(error)
      render_json({
        error: "sophtron_request_failed",
        message: error.message.presence || "Sophtron request failed"
      }, status: :bad_gateway)
    end

    def render_coinstats_link_error(message, errors)
      render_json({
        error: "coinstats_link_failed",
        message: message,
        errors: Array(errors).compact
      }, status: :unprocessable_entity)
    end

    def render_provider_validation_error(item)
      render_json({
        error: "validation_failed",
        message: "Provider connection could not be saved",
        errors: item.errors.full_messages
      }, status: :unprocessable_entity)
    end

    def render_unsupported_provider(provider_key, action:)
      render_json({
        error: "provider_not_supported",
        message: "#{provider_key.presence || 'Provider'} is not supported for API #{action}"
      }, status: :not_found)
    end

    def render_provider_not_found(action:)
      render_json({
        error: "provider_not_found",
        message: "Provider is not supported for API #{action}"
      }, status: :not_found)
    end

    def sync_metadata(provider:, status:, scheduled:, total_count: nil, scheduled_count: nil, skipped_count: nil, retry_after_seconds: nil, provider_connection_id: nil, mode: nil)
      {
        provider: provider,
        provider_connection_id: provider_connection_id,
        mode: mode,
        status: status,
        scheduled: scheduled,
        total_count: total_count,
        scheduled_count: scheduled_count,
        skipped_count: skipped_count,
        retry_after_seconds: retry_after_seconds
      }
    end

    def provider_mutation_sync_metadata(scheduled:)
      {
        scheduled: scheduled,
        status: scheduled ? "scheduled" : "not_scheduled"
      }
    end

    def provider_account_setup_sync_metadata(scheduled)
      provider_mutation_sync_metadata(scheduled: scheduled)
    end

    def managed_provider_config(provider_key)
      MANAGED_PROVIDER_CONNECTIONS[provider_key]
    end

    def create_plaid_connection
      attributes = plaid_connection_attributes
      public_token = attributes[:public_token].to_s.strip
      return render_validation_error("public_token is required") if public_token.blank?

      item = current_resource_owner.family.create_plaid_item!(
        public_token: public_token,
        item_name: attributes[:item_name].presence || attributes[:name].presence || "Plaid Connection",
        region: normalized_plaid_region(attributes[:region]).to_s
      )

      render_provider_mutation_response(
        item: item,
        provider_key: "plaid",
        message: "Provider connection created",
        sync: provider_mutation_sync_metadata(scheduled: true),
        status: :created
      )
    end

    def create_simplefin_connection
      attributes = simplefin_connection_attributes
      setup_token = attributes[:setup_token].to_s.strip
      return render_validation_error("setup_token is required") if setup_token.blank?

      item = current_resource_owner.family.create_simplefin_item!(
        setup_token: setup_token,
        item_name: attributes[:item_name].presence || attributes[:name].presence || "SimpleFIN Connection",
        sync_start_date: simplefin_sync_start_date(attributes)
      )

      render_provider_mutation_response(
        item: item,
        provider_key: "simplefin",
        message: "Provider connection created",
        sync: provider_mutation_sync_metadata(scheduled: true),
        status: :created
      )
    rescue InvalidFilterError => e
      render_validation_error(e.message)
    rescue ArgumentError, URI::InvalidURIError
      render_validation_error("setup_token is invalid")
    rescue Provider::Simplefin::SimplefinError => e
      render_simplefin_api_error(e)
    end

    def create_coinstats_connection
      attributes = coinstats_connection_attributes
      api_key = attributes[:api_key].to_s.strip
      return render_validation_error("api_key is required") if api_key.blank?
      return unless validate_coinstats_api_key(api_key)

      item = current_resource_owner.family.coinstats_items.create!(
        name: attributes[:item_name].presence || attributes[:name].presence || "CoinStats Connection",
        api_key: api_key,
        sync_start_date: coinstats_sync_start_date(attributes)
      )

      render_provider_mutation_response(
        item: item,
        provider_key: "coinstats",
        message: "Provider connection created",
        sync: provider_mutation_sync_metadata(scheduled: false),
        status: :created
      )
    rescue ActiveRecord::RecordInvalid => e
      render_provider_validation_error(e.record)
    rescue InvalidFilterError => e
      render_validation_error(e.message)
    rescue Provider::Coinstats::Error => e
      render_coinstats_api_error(e)
    end

    def update_simplefin_connection
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      item = SimplefinItem.where(family: current_resource_owner.family).find(params[:id])
      attributes = simplefin_connection_attributes
      metadata = simplefin_metadata_attributes(attributes)
      setup_token = attributes[:setup_token].to_s.strip

      ActiveRecord::Base.transaction do
        item.update!(metadata) if metadata.present?
        if setup_token.present?
          SimplefinConnectionUpdateJob.perform_later(
            family_id: current_resource_owner.family.id,
            old_simplefin_item_id: item.id,
            setup_token: setup_token
          )
        end
      end

      render_provider_mutation_response(
        item: item.reload,
        provider_key: "simplefin",
        message: setup_token.present? ? "Provider connection update scheduled" : "Provider connection updated",
        sync: provider_mutation_sync_metadata(scheduled: setup_token.present?),
        status: setup_token.present? ? :accepted : :ok
      )
    rescue ActiveRecord::RecordInvalid => e
      render_provider_validation_error(e.record)
    rescue InvalidFilterError => e
      render_validation_error(e.message)
    rescue ActiveRecord::RecordNotFound
      raise
    rescue ActionController::ParameterMissing => e
      handle_bad_request(e)
    rescue StandardError => e
      log_provider_connection_error(:update_simplefin_connection, e)

      render_json({
        error: "internal_server_error",
        message: "An unexpected error occurred"
      }, status: :internal_server_error)
    end

    def update_coinstats_connection
      item = coinstats_item
      attributes = coinstats_metadata_attributes(coinstats_connection_attributes)

      if attributes[:api_key].present?
        return unless validate_coinstats_api_key(attributes[:api_key])
      end

      item.update!(attributes)

      render_provider_mutation_response(
        item: item.reload,
        provider_key: "coinstats",
        message: "Provider connection updated",
        sync: provider_mutation_sync_metadata(scheduled: false),
        status: :ok
      )
    rescue ActiveRecord::RecordInvalid => e
      render_provider_validation_error(e.record)
    rescue InvalidFilterError => e
      render_validation_error(e.message)
    rescue ActiveRecord::RecordNotFound
      raise
    rescue ActionController::ParameterMissing => e
      handle_bad_request(e)
    rescue Provider::Coinstats::Error => e
      render_coinstats_api_error(e)
    rescue StandardError => e
      log_provider_connection_error(:update_coinstats_connection, e)

      render_json({
        error: "internal_server_error",
        message: "An unexpected error occurred"
      }, status: :internal_server_error)
    end

    def create_sophtron_connection
      attributes = sophtron_connection_attributes
      item = current_resource_owner.family.sophtron_items.build(sophtron_metadata_attributes(attributes, persisted: false))
      item.name = "Sophtron Connection" if item.name.blank?
      item.save!
      verify_and_provision_sophtron_customer!(item)

      render_provider_mutation_response(
        item: item.reload,
        provider_key: "sophtron",
        message: "Provider connection created",
        sync: provider_mutation_sync_metadata(scheduled: false),
        status: :created
      )
    rescue ActiveRecord::RecordInvalid => e
      render_provider_validation_error(e.record)
    rescue InvalidFilterError => e
      render_validation_error(e.message)
    rescue Provider::Sophtron::Error => e
      render_sophtron_api_error(e)
    end

    def update_sophtron_connection
      item = sophtron_item
      attributes = sophtron_metadata_attributes(sophtron_connection_attributes, persisted: true)
      item.update!(attributes)
      verify_and_provision_sophtron_customer!(item.reload)

      render_provider_mutation_response(
        item: item.reload,
        provider_key: "sophtron",
        message: "Provider connection updated",
        sync: provider_mutation_sync_metadata(scheduled: false),
        status: :ok
      )
    rescue ActiveRecord::RecordInvalid => e
      render_provider_validation_error(e.record)
    rescue InvalidFilterError => e
      render_validation_error(e.message)
    rescue ActiveRecord::RecordNotFound
      raise
    rescue ActionController::ParameterMissing => e
      handle_bad_request(e)
    rescue Provider::Sophtron::Error => e
      render_sophtron_api_error(e)
    rescue StandardError => e
      log_provider_connection_error(:update_sophtron_connection, e)

      render_json({
        error: "internal_server_error",
        message: "An unexpected error occurred"
      }, status: :internal_server_error)
    end

    def plaid_connection_attributes(required: true)
      source = params[:provider_connection].presence || params[:plaid_item].presence
      source ||= params if required
      return {}.with_indifferent_access unless source.respond_to?(:permit)

      source.permit(:public_token, :region, :item_name, :name, :accountable_type, :redirect_url)
            .to_h
            .with_indifferent_access
    end

    def simplefin_connection_attributes
      source = params[:provider_connection].presence || params[:simplefin_item].presence
      raise ActionController::ParameterMissing, :provider_connection unless source.respond_to?(:permit)

      source.permit(:setup_token, :name, :item_name, :sync_start_date)
            .to_h
            .with_indifferent_access
            .tap do |attributes|
              attributes.each do |key, value|
                attributes[key] = value.strip if value.is_a?(String)
              end
            end
    end

    def coinstats_item
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      CoinstatsItem.where(family: current_resource_owner.family).find(params[:id])
    end

    def coinstats_connection_attributes
      source = params[:provider_connection].presence || params[:coinstats_item].presence
      raise ActionController::ParameterMissing, :provider_connection unless source.respond_to?(:permit)

      source.permit(:api_key, :name, :item_name, :sync_start_date)
            .to_h
            .with_indifferent_access
            .tap do |attributes|
              attributes.each do |key, value|
                attributes[key] = value.strip if value.is_a?(String)
              end
            end
    end

    def coinstats_metadata_attributes(attributes)
      {}.tap do |metadata|
        metadata[:name] = attributes[:name] if attributes.key?(:name)
        metadata[:name] = attributes[:item_name] if metadata[:name].blank? && attributes.key?(:item_name)
        metadata[:sync_start_date] = coinstats_sync_start_date(attributes) if attributes.key?(:sync_start_date)
        metadata[:api_key] = attributes[:api_key] if attributes[:api_key].present?
      end
    end

    def coinstats_sync_start_date(attributes)
      return nil if attributes[:sync_start_date].blank?

      Date.iso8601(attributes[:sync_start_date].to_s)
    rescue ArgumentError, TypeError
      raise InvalidFilterError, "sync_start_date must be an ISO 8601 date"
    end

    def validate_coinstats_api_key(api_key)
      validation = Provider::Coinstats.new(api_key).get_blockchains
      return true if validation.success?

      item = CoinstatsItem.new
      item.errors.add(:api_key, validation.error&.message.presence || "could not be validated")
      render_provider_validation_error(item)
      false
    end

    def coinstats_wallet_attributes
      source = params[:wallet].presence || params[:provider_connection].presence || params
      raise ActionController::ParameterMissing, :wallet unless source.respond_to?(:permit)

      source.permit(:address, :blockchain)
            .to_h
            .with_indifferent_access
    end

    def coinstats_exchange_attributes
      source = params[:exchange].presence || params[:provider_connection].presence || params
      raise ActionController::ParameterMissing, :exchange unless source.respond_to?(:permit)

      source.permit(:connection_id, :exchange_connection_id, :name, :exchange_connection_name, connection_fields: {})
            .to_h
            .with_indifferent_access
            .tap do |attributes|
              attributes[:connection_id] = attributes[:exchange_connection_id] if attributes[:connection_id].blank?
              attributes[:name] = attributes[:exchange_connection_name] if attributes[:name].blank?
            end
    end

    def coinstats_exchange_option(item, connection_id)
      Provider::Coinstats.new(item.api_key).exchange_options.find { |exchange| exchange[:connection_id].to_s == connection_id.to_s }
    end

    def coinstats_permitted_exchange_fields(exchange, connection_fields_param)
      allowed_keys = Array(exchange[:connection_fields]).filter_map { |field| field[:key].presence&.to_s }

      coinstats_connection_fields(connection_fields_param)
        .slice(*allowed_keys)
        .transform_values { |value| value.to_s.strip }
        .compact_blank
    end

    def coinstats_connection_fields(connection_fields_param)
      raw_fields = if connection_fields_param.respond_to?(:to_unsafe_h)
        connection_fields_param.to_unsafe_h
      elsif connection_fields_param.respond_to?(:to_h)
        connection_fields_param.to_h
      else
        {}
      end

      raw_fields.with_indifferent_access
    end

    def sophtron_item
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      SophtronItem.where(family: current_resource_owner.family).find(params[:id])
    end

    def sophtron_connection_attributes
      source = params[:provider_connection].presence || params[:sophtron_item].presence
      raise ActionController::ParameterMissing, :provider_connection unless source.respond_to?(:permit)

      source.permit(:name, :item_name, :user_id, :access_key, :base_url, :sync_start_date)
            .to_h
            .with_indifferent_access
            .tap do |attributes|
              attributes.each do |key, value|
                attributes[key] = value.strip if value.is_a?(String)
              end
            end
    end

    def sophtron_metadata_attributes(attributes, persisted:)
      {}.tap do |metadata|
        metadata[:name] = attributes[:name] if attributes.key?(:name)
        metadata[:name] = attributes[:item_name] if metadata[:name].blank? && attributes.key?(:item_name)
        metadata[:user_id] = attributes[:user_id] if attributes.key?(:user_id)
        metadata[:access_key] = attributes[:access_key] if attributes.key?(:access_key)
        metadata[:base_url] = attributes[:base_url].presence if attributes.key?(:base_url)
        metadata[:base_url] = nil if attributes.key?(:base_url) && attributes[:base_url].blank?
        metadata[:sync_start_date] = sophtron_sync_start_date(attributes) if attributes.key?(:sync_start_date)

        if persisted
          metadata.delete(:user_id) if metadata.key?(:user_id) && metadata[:user_id].blank?
          metadata.delete(:access_key) if metadata.key?(:access_key) && metadata[:access_key].blank?
        end
      end
    end

    def sophtron_sync_start_date(attributes)
      return nil if attributes[:sync_start_date].blank?

      Date.iso8601(attributes[:sync_start_date].to_s)
    rescue ArgumentError, TypeError
      raise InvalidFilterError, "sync_start_date must be an ISO 8601 date"
    end

    def verify_and_provision_sophtron_customer!(item)
      provider = item.sophtron_provider
      raise Provider::Sophtron::Error.new("Sophtron provider is not configured", :configuration_error) unless provider

      sophtron_response_data!(provider.health_check_auth)
      item.ensure_customer!(provider: provider)
    rescue Provider::Sophtron::Error => e
      item.update(status: :requires_update, last_connection_error: e.message) if item&.persisted?
      raise
    end

    def sophtron_response_data!(response)
      Provider::Sophtron.response_data!(response)
    end

    def sophtron_institution_query
      (params[:query].presence || params[:institution_name].presence).to_s.strip
    end

    def sophtron_institution_payload(institution)
      institution = institution.with_indifferent_access

      {
        id: first_present(institution, :institution_id, :InstitutionID, :id, :ID),
        name: first_present(institution, :institution_name, :InstitutionName, :name, :Name),
        domain: first_present(institution, :domain, :Domain),
        url: first_present(institution, :url, :Url, :URL, :website, :Website),
        city: first_present(institution, :city, :City),
        state: first_present(institution, :state, :State),
        country: first_present(institution, :country, :Country)
      }.compact
    end

    def sophtron_institution_connection_attributes
      source = params[:connection].presence || params[:provider_connection].presence || params
      raise ActionController::ParameterMissing, :connection unless source.respond_to?(:permit)

      source.permit(:institution_id, :institution_name, :bank_username, :bank_password, :bank_pin, :new_connection)
            .to_h
            .with_indifferent_access
            .tap do |attributes|
              attributes.each do |key, value|
                attributes[key] = value.strip if value.is_a?(String)
              end
            end
    end

    def sophtron_institution_connection_item(item, attributes)
      return item unless truthy_param?(attributes[:new_connection]) && sophtron_item_needs_institution_clone?(item)

      current_resource_owner.family.sophtron_items.create!(
        name: item.name.presence || "Sophtron Connection",
        user_id: item.user_id,
        access_key: item.access_key,
        base_url: item.base_url,
        customer_id: item.customer_id,
        customer_name: item.customer_name,
        raw_customer_payload: item.raw_customer_payload,
        sync_start_date: item.sync_start_date
      )
    end

    def sophtron_item_needs_institution_clone?(item)
      item.user_institution_id.present? ||
        item.current_job_id.present? ||
        item.institution_id.present? ||
        item.institution_name.present? ||
        item.sophtron_accounts.exists?
    end

    def sophtron_connection_payload(item, status:, job: nil, job_id: nil, user_institution_id: nil, error_message: nil)
      job = job.with_indifferent_access if job.respond_to?(:with_indifferent_access)

      {
        status: status,
        job_id: job_id || item.current_job_id,
        user_institution_id: user_institution_id || item.user_institution_id,
        institution_id: item.institution_id,
        institution_name: item.institution_name,
        job_status: job&.dig(:LastStatus) || job&.dig(:last_status) || item.job_status,
        next_poll_after_seconds: sophtron_connection_next_poll_seconds(status),
        error_message: error_message
      }.compact
    end

    def sophtron_connection_next_poll_seconds(status)
      return nil unless %w[pending completed mfa_submitted].include?(status)

      SOPHTRON_CONNECTION_STATUS_POLL_INTERVAL_SECONDS
    end

    def sophtron_account_setup_payload(item)
      provider_definition = provider_definition_for("sophtron")
      provider_accounts = provider_account_relation(item, provider_definition).reject { |provider_account| provider_account_linked?(provider_account) }

      {
        pending: item.pending_account_setup?,
        unlinked_count: provider_accounts.count,
        provider_accounts: provider_accounts.map { |provider_account| provider_account_payload(provider_account, provider_definition) }
      }
    end

    def sophtron_mfa_challenge_payload(challenge)
      challenge = challenge.with_indifferent_access

      {
        security_questions: Array(challenge[:security_questions]),
        token_methods: Array(challenge[:token_methods]),
        token_sent: !!challenge[:token_sent],
        token_read: challenge[:token_read],
        captcha_image: challenge[:captcha_image]
      }.compact
    end

    def sophtron_mfa_attributes
      source = params[:mfa].presence || params[:provider_connection].presence || params
      raise ActionController::ParameterMissing, :mfa unless source.respond_to?(:permit)

      source.permit(:mfa_type, :token_choice, :token_input, :captcha_input, :verify_phone, security_answers: [])
            .to_h
            .with_indifferent_access
            .tap do |attributes|
              attributes.each do |key, value|
                attributes[key] = value.strip if value.is_a?(String)
              end
            end
    end

    def sophtron_manual_sync_attributes
      source = params[:manual_sync].presence || params[:provider_connection].presence || params
      raise ActionController::ParameterMissing, :manual_sync unless source.respond_to?(:permit)

      source.permit(:enabled, :institution_key, :user_institution_id)
            .to_h
            .with_indifferent_access
            .tap do |attributes|
              attributes.each do |key, value|
                attributes[key] = value.strip if value.is_a?(String)
              end
            end
    end

    def manual_sync_requested_enabled(attributes)
      return nil unless attributes.key?(:enabled)

      ActiveModel::Type::Boolean.new.cast(attributes[:enabled])
    end

    def sophtron_manual_sync_scoped?(attributes)
      attributes[:institution_key].present? || attributes[:user_institution_id].present?
    end

    def sophtron_manual_sync_target_accounts(item, attributes)
      accounts = item.sophtron_accounts.joins(:account_provider).order(:created_at, :id)
      institution_key = attributes[:institution_key].presence || attributes[:user_institution_id].presence
      return accounts if institution_key.blank?

      matching_ids = accounts.select do |sophtron_account|
        sophtron_account.institution_key.to_s == institution_key.to_s
      end.map(&:id)

      accounts.where(id: matching_ids)
    end

    def sophtron_manual_sync_payload(item, target_accounts, enabled, scoped:)
      affected_account_ids = scoped && target_accounts.exists? ? target_accounts.pluck(:id) : []

      {
        enabled: enabled,
        provider_level_enabled: item.manual_sync?,
        scoped: scoped,
        affected_account_ids: affected_account_ids,
        manual_account_ids: item.sophtron_accounts.requires_manual_sync.order(:created_at, :id).pluck(:id)
      }
    end

    def sophtron_security_answers(attributes)
      raw_answers = Array(attributes[:security_answers]).flatten
      return if raw_answers.size > SOPHTRON_MAX_SECURITY_ANSWERS
      return if raw_answers.any? { |answer| answer.to_s.length > SOPHTRON_MAX_SECURITY_ANSWER_LENGTH }

      raw_answers.filter_map { |answer| answer.to_s.strip.presence }
    end

    def sophtron_connection_failure_message(job)
      job = job.with_indifferent_access
      last_status = (job[:LastStatus] || job[:last_status]).to_s
      return "Sophtron connection timed out" if last_status.match?(/timeout/i)

      "Sophtron connection failed"
    end

    def enable_banking_item
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      EnableBankingItem.where(family: current_resource_owner.family).find(params[:id])
    end

    def enable_banking_authorization_attributes
      source = params[:authorization].presence || params[:provider_connection].presence || params
      raise ActionController::ParameterMissing, :authorization unless source.respond_to?(:permit)

      source.permit(:aspsp_name, :psu_type, :redirect_url, :language, :new_connection)
            .to_h
            .with_indifferent_access
            .tap do |attributes|
              attributes.each do |key, value|
                attributes[key] = value.strip if value.is_a?(String)
              end
            end
    end

    def enable_banking_authorization_completion_attributes
      source = params[:authorization].presence || params[:provider_connection].presence || params
      raise ActionController::ParameterMissing, :authorization unless source.respond_to?(:permit)

      source.permit(:code, :state)
            .to_h
            .with_indifferent_access
    end

    def enable_banking_authorization_item(item, attributes)
      return item unless truthy_param?(attributes[:new_connection])

      current_resource_owner.family.enable_banking_items.create!(
        name: item.name.presence || "Enable Banking Connection",
        country_code: item.country_code,
        application_id: item.application_id,
        client_certificate: item.client_certificate
      )
    end

    def enable_banking_bank_payload(aspsp)
      aspsp = aspsp.with_indifferent_access

      {
        name: aspsp[:name],
        country: aspsp[:country],
        bic: aspsp[:bic],
        beta: !!aspsp[:beta],
        logo: aspsp[:logo],
        psu_types: Array(aspsp[:psu_types]),
        auth_methods: Array(aspsp[:auth_methods])
      }
    end

    def replacement_suggestion_attributes
      source = params[:replacement_suggestion].presence || params[:provider_connection].presence || params
      raise ActionController::ParameterMissing, :replacement_suggestion unless source.respond_to?(:permit)

      source.permit(:dormant_sfa_id, :active_sfa_id)
            .to_h
            .with_indifferent_access
            .tap do |attributes|
              attributes.each do |key, value|
                attributes[key] = value.strip if value.is_a?(String)
              end
            end
            .tap do |attributes|
              raise ActionController::ParameterMissing, :dormant_sfa_id if attributes[:dormant_sfa_id].blank?
              raise ActionController::ParameterMissing, :active_sfa_id if attributes[:active_sfa_id].blank?
            end
    end

    def simplefin_account_ids_belong_to_item?(item, dormant_sfa_id, active_sfa_id)
      return false unless valid_uuid?(dormant_sfa_id) && valid_uuid?(active_sfa_id)

      matching_ids = item.simplefin_accounts.where(id: [ dormant_sfa_id, active_sfa_id ]).pluck(:id).map(&:to_s)
      [ dormant_sfa_id, active_sfa_id ].all? { |id| matching_ids.include?(id) }
    end

    def simplefin_metadata_attributes(attributes)
      {}.tap do |metadata|
        metadata[:name] = attributes[:name] if attributes.key?(:name)
        metadata[:name] = attributes[:item_name] if metadata[:name].blank? && attributes.key?(:item_name)
        metadata[:sync_start_date] = simplefin_sync_start_date(attributes) if attributes.key?(:sync_start_date)
      end
    end

    def simplefin_sync_start_date(attributes)
      return nil if attributes[:sync_start_date].blank?

      Date.iso8601(attributes[:sync_start_date].to_s)
    rescue ArgumentError, TypeError
      raise InvalidFilterError, "sync_start_date must be an ISO 8601 date"
    end

    def normalized_plaid_region(region)
      region.to_s.downcase == "eu" ? :eu : :us
    end

    def plaid_accountable_type(attributes)
      account_type = attributes[:accountable_type].presence || "Depository"
      return account_type if Provider::PlaidAdapter.supported_account_types.include?(account_type)

      "Depository"
    end

    def plaid_redirect_url(attributes)
      attributes[:redirect_url].presence || accounts_url
    end

    def plaid_webhooks_url(region)
      if region.to_sym == :eu
        return webhooks_plaid_eu_url if Rails.env.production?

        "#{ENV.fetch('DEV_WEBHOOKS_URL', root_url.chomp('/'))}/webhooks/plaid_eu"
      else
        return webhooks_plaid_url if Rails.env.production?

        "#{ENV.fetch('DEV_WEBHOOKS_URL', root_url.chomp('/'))}/webhooks/plaid"
      end
    end

    def safe_parse_plaid_error(error)
      JSON.parse(error.response_body.to_s)
    rescue JSON::ParserError
      {}
    end

    def snaptrade_oauth_attributes
      source = params[:provider_connection].presence || params[:oauth].presence || params
      return {}.with_indifferent_access unless source.respond_to?(:permit)

      source.permit(:provider_connection_id, :id, :scope, :name)
            .to_h
            .with_indifferent_access
            .tap do |attributes|
              attributes.each do |key, value|
                attributes[key] = value.strip if value.is_a?(String)
              end
            end
    end

    def snaptrade_oauth_item
      attributes = snaptrade_oauth_attributes
      item_id = attributes[:provider_connection_id].presence || attributes[:id].presence

      if item_id.present?
        raise ActiveRecord::RecordNotFound unless valid_uuid?(item_id)

        return SnaptradeItem.where(family: current_resource_owner.family).find(item_id)
      end

      current_snaptrade_item || current_resource_owner.family.snaptrade_items.create!(
        name: attributes[:name].presence || I18n.t("snaptrade_items.default_name", default: "SnapTrade Connection")
      )
    end

    def current_snaptrade_item
      active_items = current_resource_owner.family.snaptrade_items.active

      active_items.syncable.ordered.first ||
        active_items.credentials_configured.ordered.first ||
        active_items.ordered.first
    end

    def snaptrade_oauth_scope
      requested_scope = snaptrade_oauth_attributes[:scope].to_s
      return requested_scope if SNAPTRADE_PERMITTED_OAUTH_SCOPES.include?(requested_scope)

      "read"
    end

    def snaptrade_device_authorization_payload(authorization)
      authorization = authorization.to_h.with_indifferent_access

      {
        device_code: authorization[:device_code],
        user_code: authorization[:user_code],
        verification_uri: authorization[:verification_uri],
        verification_uri_complete: authorization[:verification_uri_complete],
        expires_in: authorization[:expires_in],
        interval: authorization[:interval],
        scope: authorization[:scope]
      }.compact
    end

    def snaptrade_device_code
      params.dig(:provider_connection, :device_code).presence ||
        params.dig(:oauth, :device_code).presence ||
        params[:device_code].presence
    end

    def snaptrade_oauth_token_payload(token_response, item)
      token_response = token_response.to_h.with_indifferent_access

      {
        token_type: token_response[:token_type],
        scope: token_response[:scope],
        expires_in: token_response[:expires_in],
        expires_at: item.oauth_token_expires_at&.iso8601
      }
    end

    def prepare_snaptrade_oauth_account_setup(item)
      requires_api_credentials = !item.credentials_configured?
      sync_scheduled = false

      if item.credentials_configured?
        item.ensure_user_registered! unless item.user_registered?
        if item.user_registered? && !item.syncing?
          item.sync_later
          sync_scheduled = true
        end
      end

      {
        ready: item.user_registered?,
        sync_scheduled: sync_scheduled,
        requires_api_credentials: requires_api_credentials
      }
    end

    def render_snaptrade_oauth_not_configured
      render_json({
        error: "provider_not_configured",
        message: "SnapTrade OAuth client ID is not configured"
      }, status: :unprocessable_entity)
    end

    def render_snaptrade_oauth_error(message)
      render_json({
        error: "snaptrade_oauth_failed",
        message: message
      }, status: :unprocessable_entity)
    end

    def snaptrade_oauth_error_payload(error)
      parsed_body = parse_snaptrade_oauth_error_body(error.response_body)
      payload = parsed_body.slice("error", "error_description", "error_uri", "interval")
      payload["error"] ||= "snaptrade_oauth_failed"
      payload["message"] = payload["error_description"].presence || error.message
      payload
    end

    def parse_snaptrade_oauth_error_body(response_body)
      return {} if response_body.blank?

      parsed_body = JSON.parse(response_body)
      parsed_body.is_a?(Hash) ? parsed_body : {}
    rescue JSON::ParserError
      {}
    end

    def provider_definition_for(provider_key)
      PROVIDER_CONNECTION_DEFINITIONS[provider_key]
    end

    def provider_connection_item(provider_definition)
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      provider_definition[:type].constantize
                                .where(family: current_resource_owner.family)
                                .find(params[:id])
    end

    def provider_account_relation(item, provider_definition)
      relation = item.public_send(provider_definition[:accounts])
      includes = []
      klass = relation.klass

      includes << :account_provider if klass.reflect_on_association(:account_provider)
      includes << :account if klass.reflect_on_association(:account)
      includes << :linked_account if klass.reflect_on_association(:linked_account)

      relation = relation.includes(*includes) if includes.any?
      relation.order(created_at: :asc)
    end

    def provider_model(config)
      config[:type].constantize
    end

    def build_provider_connection(config)
      provider_model(config).new(provider_connection_attributes(config)).tap do |item|
        item.family = current_resource_owner.family
        item.name = config[:default_name] if item.name.blank?
      end
    end

    def provider_connection_attributes(config, persisted: false)
      source = provider_connection_param_source(config)
      attributes = source.permit(*config[:fields]).to_h.with_indifferent_access

      normalize_provider_connection_attributes!(attributes, config, persisted: persisted)
      attributes
    end

    def provider_connection_param_source(config)
      source = params[:provider_connection].presence || params[config[:param_key]].presence
      raise ActionController::ParameterMissing, :provider_connection unless source.respond_to?(:permit)

      source
    end

    def normalize_provider_connection_attributes!(attributes, config, persisted:)
      preserve_whitespace_fields = Array(config[:preserve_whitespace_fields]).map(&:to_sym)

      attributes.each do |key, value|
        next unless value.is_a?(String)
        next if preserve_whitespace_fields.include?(key.to_sym)

        attributes[key] = value.strip
      end

      Array(config[:nullable_blank_fields]).each do |key|
        attributes[key] = nil if attributes.key?(key) && attributes[key].blank?
      end

      return unless persisted

      Array(config[:secret_fields]).each do |key|
        attributes.delete(key) if attributes.key?(key) && attributes[key].blank?
      end
    end

    def run_provider_after_create_hook(item, config)
      hook = config[:after_create]
      item.public_send(hook) if hook
    end

    def schedule_initial_provider_sync(item, config)
      return false unless config[:initial_sync]
      return false if item.syncing?

      item.sync_later
      true
    end

    def schedule_provider_connection_sync(item, mode: "full")
      if item.is_a?(SimplefinItem) && mode == "balances_only"
        sync = item.syncs.create!(status: :pending)
        SyncJob.perform_later(sync, balances_only: true)
        return true
      end

      return false unless item.respond_to?(:sync_later)
      return false if item.respond_to?(:syncing?) && item.syncing?

      item.sync_later
      true
    end

    def provider_account_setup_attributes
      source = params[:provider_account].presence || params[:account].presence || params
      raise ActionController::ParameterMissing, :provider_account unless source.respond_to?(:permit)

      source.permit(:action, :account_id, :accountable_type, :subtype, :name, :balance, :cash_balance, :currency, :opening_balance_date)
            .to_h
            .with_indifferent_access
    end

    def skip_provider_account_setup(item:, provider_definition:, provider_account:)
      return render_provider_account_conflict("Provider account is already linked") if provider_account_linked?(provider_account)

      unless provider_account.respond_to?(:ignored=)
        return render_json({
          error: "provider_account_action_not_supported",
          message: "Provider account cannot be skipped"
        }, status: :unprocessable_entity)
      end

      provider_account.update!(ignored: true)

      render_provider_account_setup_response(
        item: item,
        provider_definition: provider_definition,
        provider_account: provider_account,
        account: nil,
        message: "Provider account skipped",
        sync_scheduled: false,
        status: :ok
      )
    end

    def find_linkable_account!(account_id, provider_definition)
      raise ActiveRecord::RecordNotFound unless valid_uuid?(account_id)

      account = current_resource_owner.family.accounts.listable_manual.find(account_id)
      validate_supported_account_type!(account.accountable_type, provider_definition)
      account
    end

    def create_account_from_provider_account!(provider_account, provider_definition, attributes)
      account_type = attributes[:accountable_type].presence || suggested_account_type_for(provider_account, provider_definition)
      validate_supported_account_type!(account_type, provider_definition)

      balance = provider_account_balance(provider_account, account_type, override: attributes[:balance])
      subtype = attributes[:subtype].presence || suggested_subtype_for(provider_account, account_type)

      Account.create_and_sync(
        {
          family: current_resource_owner.family,
          owner: current_resource_owner,
          name: attributes[:name].presence || provider_account_value(provider_account, :name).presence || "#{provider_definition[:key].humanize} Account",
          balance: balance,
          cash_balance: provider_account_cash_balance(provider_account, account_type, balance, override: attributes[:cash_balance]),
          currency: attributes[:currency].presence || provider_account_value(provider_account, :currency).presence || current_resource_owner.family.currency,
          accountable_type: account_type,
          accountable_attributes: accountable_attributes_for(account_type, subtype)
        },
        skip_initial_sync: true,
        opening_balance_date: parse_optional_date(attributes[:opening_balance_date])
      )
    end

    def validate_supported_account_type!(account_type, provider_definition)
      supported_account_types = supported_account_types_for(provider_definition)

      if account_type.blank?
        raise ActiveRecord::RecordInvalid.new(
          Account.new.tap { |account| account.errors.add(:accountable_type, "is required") }
        )
      end

      return if Accountable::TYPES.include?(account_type) && supported_account_types.include?(account_type)

      raise ActiveRecord::RecordInvalid.new(
        Account.new.tap do |account|
          account.errors.add(:accountable_type, "must be one of: #{supported_account_types.join(', ')}")
        end
      )
    end

    def ensure_provider_account_link!(provider_account, account)
      provider_link = AccountProvider.find_or_initialize_by(
        provider_type: provider_account.class.name,
        provider_id: provider_account.id
      )
      provider_link.account = account
      provider_link.save!
      provider_account.reload
      provider_link
    end

    def parse_optional_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      raise InvalidFilterError, "opening_balance_date must be an ISO 8601 date"
    end

    def provider_account_balance(provider_account, account_type, override: nil)
      balance = decimal_value(override.presence)
      balance ||= decimal_value(provider_account_value(provider_account, :current_balance))
      balance ||= decimal_value(provider_account_value(provider_account, :available_balance))
      balance ||= decimal_value(provider_account_value(provider_account, :balance))
      balance ||= BigDecimal("0")

      %w[CreditCard Loan].include?(account_type) ? balance.abs : balance
    end

    def provider_account_cash_balance(provider_account, account_type, balance, override: nil)
      override_balance = decimal_value(override.presence)
      return override_balance if override_balance

      case account_type
      when "Crypto"
        BigDecimal("0")
      when "Investment"
        decimal_value(provider_account_value(provider_account, :cash_balance)) || BigDecimal("0")
      else
        balance
      end
    end

    def accountable_attributes_for(account_type, subtype)
      attributes = {}
      attributes[:subtype] = subtype.presence || default_subtype_for(account_type)
      attributes.compact!

      attributes[:tax_treatment] = "taxable" if account_type == "Crypto"
      attributes
    end

    def default_subtype_for(account_type)
      case account_type
      when "Depository"
        Depository::DEFAULT_SUBTYPE
      when "CreditCard"
        CreditCard::DEFAULT_SUBTYPE
      when "Investment"
        "brokerage"
      when "Crypto"
        "exchange"
      end
    end

    def suggested_account_type_for(provider_account, provider_definition)
      suggestion = provider_account_value(provider_account, :suggested_account_type)
      return suggestion if suggestion.present?

      if provider_account.class.respond_to?(:default_account_type_for)
        suggestion = provider_account.class.default_account_type_for(provider_account)
        return suggestion if suggestion.present?
      end

      supported_account_types = supported_account_types_for(provider_definition)
      supported_account_types.one? ? supported_account_types.first : nil
    end

    def suggested_subtype_for(provider_account, account_type)
      provider_account_value(provider_account, :suggested_subtype).presence || default_subtype_for(account_type)
    end

    def supported_account_types_for(provider_definition)
      adapter_class = provider_adapter_class(provider_definition[:key])
      return [] unless adapter_class&.respond_to?(:supported_account_types)

      supported_types = adapter_class.supported_account_types
      supported_types += %w[Crypto OtherAsset] if provider_definition[:key] == "simplefin"
      supported_types.uniq
    end

    def provider_adapter_class(provider_key)
      "Provider::#{provider_key.camelize}Adapter".constantize
    rescue NameError
      nil
    end

    def provider_connection_status_for_item(item, provider_key)
      ProviderConnectionStatus.for_family(current_resource_owner.family)
                              .detect { |connection| connection[:id] == item.id && connection[:provider] == provider_key }
    end

    def provider_accounts_meta(provider_accounts, unlinked_only:)
      linked_count = provider_accounts.count { |provider_account| provider_account_linked?(provider_account) }

      {
        total_count: provider_accounts.count,
        linked_count: linked_count,
        unlinked_count: provider_accounts.count - linked_count,
        unlinked_only: unlinked_only
      }
    end

    def provider_account_payload(provider_account, provider_definition)
      linked_account = provider_account_linked_account(provider_account)
      account_type_suggestion = suggested_account_type_for(provider_account, provider_definition)

      {
        id: provider_account.id,
        provider: provider_definition[:key],
        provider_type: provider_account.class.name,
        provider_connection_id: provider_account.public_send("#{provider_definition[:key]}_item_id"),
        provider_connection_type: provider_definition[:type],
        name: provider_account_value(provider_account, :name),
        currency: provider_account_value(provider_account, :currency),
        current_balance: decimal_string(provider_account_value(provider_account, :current_balance)),
        available_balance: decimal_string(provider_account_value(provider_account, :available_balance)),
        cash_balance: decimal_string(provider_account_value(provider_account, :cash_balance)),
        account_status: provider_account_value(provider_account, :account_status),
        account_type: provider_account_value(provider_account, :account_type),
        institution: provider_account_institution_payload(provider_account),
        supported_account_types: supported_account_types_for(provider_definition),
        suggested_accountable_type: account_type_suggestion,
        suggested_subtype: suggested_subtype_for(provider_account, account_type_suggestion),
        linked: linked_account.present?,
        ignored: provider_account.respond_to?(:ignored) ? provider_account.ignored : nil,
        linked_account: account_payload(linked_account),
        created_at: provider_account.created_at,
        updated_at: provider_account.updated_at
      }
    end

    def provider_account_institution_payload(provider_account)
      metadata = provider_account_value(provider_account, :institution_metadata)
      metadata = metadata.with_indifferent_access if metadata.respond_to?(:with_indifferent_access)

      {
        name: metadata&.dig(:name) || metadata&.dig(:provider_name),
        domain: metadata&.dig(:domain),
        url: metadata&.dig(:url)
      }
    end

    def provider_account_linked?(provider_account)
      provider_account_linked_account(provider_account).present?
    end

    def provider_account_linked_account(provider_account)
      if provider_account.respond_to?(:account_provider) && provider_account.account_provider.present?
        provider_account.account_provider.account
      elsif provider_account.respond_to?(:linked_account)
        provider_account.linked_account
      elsif provider_account.respond_to?(:account)
        provider_account.account
      elsif provider_account.respond_to?(:current_account)
        provider_account.current_account
      end
    end

    def provider_account_value(provider_account, method_name)
      provider_account.public_send(method_name) if provider_account.respond_to?(method_name)
    end

    def first_present(hash, *keys)
      keys.each do |key|
        value = hash[key]
        return value if value.present?
      end

      nil
    end

    def account_payload(account)
      return nil unless account

      {
        id: account.id,
        name: account.name,
        account_type: account.accountable_type,
        subtype: account.subtype,
        classification: account.classification,
        currency: account.currency,
        balance: decimal_string(account.balance),
        cash_balance: decimal_string(account.cash_balance),
        status: account.status,
        manual: account.manual?,
        created_at: account.created_at,
        updated_at: account.updated_at
      }
    end

    def decimal_value(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def decimal_string(value)
      decimal = decimal_value(value)
      decimal&.to_s("F")
    end

    def truthy_param?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def provider_connection_sync_mode
      source = params[:provider_connection].presence || params
      mode = source.respond_to?(:[]) ? source[:mode].presence : nil
      mode = mode.to_s

      return "full" if mode.blank?
      return mode if %w[full balances_only].include?(mode)

      raise InvalidFilterError, "mode must be one of: full, balances_only"
    end

    def provider_sync_status(items, scheduled_items)
      return "no_items" if items.empty?
      return "already_syncing" if scheduled_items.empty?

      "scheduled"
    end

    def provider_sync_message(provider_key, items, scheduled_items)
      provider_name = provider_key.humanize

      if items.empty?
        "No #{provider_name} connections are available to sync"
      elsif scheduled_items.empty?
        "#{provider_name} connections are already syncing"
      else
        "#{provider_name} sync started"
      end
    end

    def provider_connection_sync_message(provider_key, scheduled, mode:)
      provider_name = provider_key.humanize
      sync_label = mode == "balances_only" ? "balances-only sync" : "sync"

      scheduled ? "#{provider_name} #{sync_label} started" : "#{provider_name} connection is already syncing"
    end

    def sync_all_retry_after_seconds(family)
      attempted_at = family.reload.last_sync_all_attempted_at
      return SYNC_ALL_THROTTLE.to_i unless attempted_at

      [ (attempted_at + SYNC_ALL_THROTTLE - Time.current).ceil, 1 ].max
    end

    def log_provider_connection_error(action, error)
      Rails.logger.error "ProviderConnectionsController##{action} error: #{error.message}"
      error.backtrace&.each { |line| Rails.logger.error line }
    end
end
