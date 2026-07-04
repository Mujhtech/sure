# frozen_string_literal: true

class Api::V1::AccountTypesController < Api::V1::BaseController
  before_action :ensure_read_scope

  def index
    render_json({
      data: Accountable::TYPES.map { |type| account_type_payload(type.constantize) }
    })
  rescue StandardError => e
    Rails.logger.error "AccountTypesController#index error: #{e.message}"
    e.backtrace&.each { |line| Rails.logger.error line }

    render_json({
      error: "internal_server_error",
      message: "Account types could not be loaded"
    }, status: :internal_server_error)
  end

  private

    def account_type_payload(accountable)
      instance = accountable.new

      {
        type: accountable.name,
        key: accountable.name.underscore,
        name: accountable.singular_display_name,
        plural_name: accountable.display_name,
        classification: accountable.classification,
        favorable_direction: accountable.favorable_direction,
        icon: accountable.icon,
        color: accountable.color,
        balance_display_name: instance.balance_display_name,
        opening_balance_display_name: instance.opening_balance_display_name,
        default_subtype: default_subtype_for(accountable),
        subtypes: subtype_payloads(accountable),
        provider_connections: provider_connection_payloads(accountable)
      }
    end

    def subtype_payloads(accountable)
      subtypes = accountable.const_defined?(:SUBTYPES, false) ? accountable::SUBTYPES : {}

      subtypes.map do |key, metadata|
        metadata = metadata.to_h.with_indifferent_access

        {
          key: key,
          short_name: accountable.subtype_label_for(key, format: :short),
          name: accountable.subtype_label_for(key, format: :long),
          region: metadata[:region],
          tax_treatment: metadata[:tax_treatment]&.to_s
        }.compact
      end
    end

    def provider_connection_payloads(accountable)
      Provider::Factory
        .connection_configs_for_account_type(account_type: accountable.name, family: current_resource_owner.family)
        .map { |config| provider_connection_payload(config) }
    rescue ActiveRecord::Encryption::Errors::Configuration
      []
    end

    def provider_connection_payload(config)
      {
        key: config[:key].to_s,
        name: config[:name],
        description: config[:description],
        can_connect: ActiveModel::Type::Boolean.new.cast(config[:can_connect]),
        supports_new_account: config[:new_account_path].present?,
        supports_existing_account: config[:existing_account_path].present?
      }
    end

    def default_subtype_for(accountable)
      accountable.const_defined?(:DEFAULT_SUBTYPE, false) ? accountable::DEFAULT_SUBTYPE : nil
    end
end
