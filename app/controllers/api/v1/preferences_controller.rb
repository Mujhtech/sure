# frozen_string_literal: true

class Api::V1::PreferencesController < Api::V1::BaseController
  BOOLEAN = ActiveModel::Type::Boolean.new

  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: :update

  def show
    render_preferences
  end

  def update
    user = current_resource_owner
    updates = preference_updates

    user.transaction do
      user.lock!
      merged = (user.preferences || {}).deep_dup
      updates.each do |key, value|
        if value.is_a?(Hash)
          merged[key] ||= {}
          merged[key] = merged[key].deep_merge(value)
        else
          merged[key] = value
        end
      end
      user.update!(preferences: merged)
    end

    render_preferences
  rescue ActionController::ParameterMissing
    render_json({
      error: "bad_request",
      message: "preferences parameter is required"
    }, status: :bad_request)
  rescue ActiveRecord::RecordInvalid => e
    render_json({
      error: "validation_failed",
      message: "Preferences could not be updated",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity)
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def render_preferences
      user = current_resource_owner

      render_json({
        preferences: preferences_payload(user),
        options: options_payload
      })
    end

    def preferences_payload(user)
      raw = user.preferences || {}

      {
        raw: raw,
        appearance: {
          dashboard_two_column: user.dashboard_two_column?,
          show_split_grouped: user.show_split_grouped?
        },
        preview_features_enabled: user.preview_features_enabled?,
        dashboard: {
          collapsed_sections: raw.fetch("collapsed_sections", {}),
          section_order: user.dashboard_section_order,
          section_layout: raw.fetch("dashboard_section_layout", {})
        },
        reports: {
          collapsed_sections: raw.fetch("reports_collapsed_sections", {}),
          section_order: user.reports_section_order
        },
        transactions: {
          collapsed_sections: raw.fetch("transactions_collapsed_sections", {})
        }
      }
    end

    def options_payload
      {
        dashboard_sections: PagesController::DASHBOARD_SECTION_LAYOUTS.keys,
        dashboard_height_presets: PagesController::DASHBOARD_HEIGHT_PRESETS,
        dashboard_default_height_preset: PagesController::DEFAULT_HEIGHT_PRESET,
        dashboard_widths: %w[single full],
        default_dashboard_section_order: current_resource_owner.send(:default_dashboard_section_order),
        report_sections: %w[net_worth trends_insights investment_performance investment_flows transactions_breakdown],
        default_reports_section_order: current_resource_owner.send(:default_reports_section_order)
      }
    end

    def preference_updates
      prefs = params.require(:preferences)
      updates = {}

      boolean_preference(updates, prefs, :preview_features_enabled, "preview_features_enabled")
      boolean_preference(updates, prefs, :show_split_grouped, "show_split_grouped")
      boolean_preference(updates, prefs, :dashboard_two_column, "dashboard_two_column")

      dashboard = nested_preference_group(prefs[:dashboard])
      if dashboard.present?
        updates["collapsed_sections"] = hash_preference(dashboard[:collapsed_sections]) if dashboard.key?(:collapsed_sections)
        updates["section_order"] = array_preference(dashboard[:section_order]) if dashboard.key?(:section_order)
        updates["dashboard_section_layout"] = hash_preference(dashboard[:section_layout]) if dashboard.key?(:section_layout)
      end

      reports = nested_preference_group(prefs[:reports])
      if reports.present?
        updates["reports_collapsed_sections"] = hash_preference(reports[:collapsed_sections]) if reports.key?(:collapsed_sections)
        updates["reports_section_order"] = array_preference(reports[:section_order]) if reports.key?(:section_order)
      end

      transactions = nested_preference_group(prefs[:transactions])
      if transactions.present?
        updates["transactions_collapsed_sections"] = hash_preference(transactions[:collapsed_sections]) if transactions.key?(:collapsed_sections)
      end

      # Also accept the storage keys directly for clients that mirror the web payloads.
      updates["collapsed_sections"] = hash_preference(prefs[:collapsed_sections]) if prefs.key?(:collapsed_sections)
      updates["section_order"] = array_preference(prefs[:section_order]) if prefs.key?(:section_order)
      updates["dashboard_section_layout"] = hash_preference(prefs[:dashboard_section_layout]) if prefs.key?(:dashboard_section_layout)
      updates["reports_collapsed_sections"] = hash_preference(prefs[:reports_collapsed_sections]) if prefs.key?(:reports_collapsed_sections)
      updates["reports_section_order"] = array_preference(prefs[:reports_section_order]) if prefs.key?(:reports_section_order)
      updates["transactions_collapsed_sections"] = hash_preference(prefs[:transactions_collapsed_sections]) if prefs.key?(:transactions_collapsed_sections)

      updates
    end

    def nested_preference_group(value)
      return value if value.respond_to?(:key?)

      {}
    end

    def boolean_preference(updates, prefs, param_key, storage_key)
      return unless prefs.key?(param_key)

      updates[storage_key] = BOOLEAN.cast(prefs[param_key])
    end

    def hash_preference(value)
      return value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      return value.to_h if value.respond_to?(:to_h)

      {}
    end

    def array_preference(value)
      Array(value).map(&:to_s)
    end
end
