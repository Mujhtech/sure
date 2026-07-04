# frozen_string_literal: true

class Api::V1::UsersController < Api::V1::BaseController
  before_action :ensure_read_scope, only: %i[show reset_status]
  before_action :ensure_write_scope, except: %i[show reset_status]
  before_action :ensure_admin, only: %i[reset reset_with_sample_data reset_status]

  def show
    render_user_profile
  end

  def update
    user = current_resource_owner
    attrs = user_profile_params.to_h
    family_attrs = (attrs.delete("family") || attrs.delete("family_attributes") || {}).compact_blank

    if family_attrs.present? && !user.admin?
      render_json({ error: "forbidden", message: "Family settings can only be changed by an admin" }, status: :forbidden)
      return
    end

    if ActiveModel::Type::Boolean.new.cast(attrs["ai_enabled"]) && !user.ai_available?
      render_json({ error: "forbidden", message: "AI is not available for your account" }, status: :forbidden)
      return
    end

    email = attrs.delete("email").to_s.strip.presence
    email_changed = email.present? && email != user.email

    User.transaction do
      if family_attrs.present?
        unless user.family.update(family_attrs)
          render_family_validation_error(user.family)
          raise ActiveRecord::Rollback
        end
      end

      if attrs.present?
        unless user.update(attrs)
          render_user_validation_error(user)
          raise ActiveRecord::Rollback
        end
      end

      if email_changed && !user.initiate_email_change(email)
        render_user_validation_error(user, message: "Email could not be updated")
        raise ActiveRecord::Rollback
      end
    end

    return if performed?

    @email_change_requested = email_changed
    render_user_profile
  end

  def reset
    enqueue_family_reset(
      message: "Account reset has been initiated",
      sample_data: false
    )
  end

  def reset_with_sample_data
    enqueue_family_reset(
      message: "Account reset with sample data has been initiated",
      sample_data: true,
      load_sample_data_for_email: current_resource_owner.email
    )
  end

  def reset_status
    family = current_resource_owner.family
    counts = reset_target_counts(family)
    reset_complete = counts.values.sum.zero?

    render json: {
      status: reset_complete ? "complete" : "data_remaining",
      family_id: family.id,
      reset_complete: reset_complete,
      counts: counts
    }
  end

  def destroy
    user = current_resource_owner

    if user.deactivate
      render json: { message: "Account has been deleted" }
    else
      render json: { error: "Failed to delete account", details: user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def rule_prompt_settings
    current_resource_owner.update!(rule_prompt_settings_params)
    render_user_profile
  rescue ActiveRecord::RecordInvalid => e
    render_user_validation_error(e.record)
  end

  def update_password
    user = current_resource_owner

    if user.update(password_update_params)
      render_user_profile
    else
      render_user_validation_error(user, message: "Password could not be updated")
    end
  end

  private

    def enqueue_family_reset(message:, sample_data:, load_sample_data_for_email: nil)
      family = current_resource_owner.family
      begin
        job = if load_sample_data_for_email.present?
          FamilyResetJob.perform_later(family, load_sample_data_for_email: load_sample_data_for_email)
        else
          FamilyResetJob.perform_later(family)
        end
      rescue StandardError => e
        Rails.logger.error "Failed to enqueue FamilyResetJob for family #{family.id}: #{e.message}"

        render json: {
          error: "reset_enqueue_failed",
          message: "Account reset could not be queued"
        }, status: :internal_server_error
        return
      end

      render json: {
        message: message,
        status: "queued",
        job_id: job.job_id,
        family_id: family.id,
        sample_data: sample_data,
        status_url: api_v1_users_reset_status_path
      }
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_admin
      return true if current_resource_owner&.admin?

      render_json({ error: "forbidden", message: "You are not authorized to perform this action" }, status: :forbidden)
      false
    end

    def user_profile_params
      params.require(:user).permit(
        :first_name,
        :last_name,
        :email,
        :onboarded_at,
        :show_sidebar,
        :default_period,
        :default_account_order,
        :show_ai_sidebar,
        :ai_enabled,
        :theme,
        :set_onboarding_preferences_at,
        :set_onboarding_goals_at,
        :locale,
        goals: [],
        family: family_profile_params,
        family_attributes: family_profile_params
      )
    end

    def family_profile_params
      permitted = %i[name currency country date_format timezone locale month_start_day]
      if current_resource_owner&.admin?
        permitted += %i[moniker default_account_sharing]
        permitted << { enabled_currencies: [] }
      end
      permitted
    end

    def rule_prompt_settings_params
      params.require(:user).permit(:rule_prompt_dismissed_at, :rule_prompts_disabled)
    end

    def password_update_params
      params.require(:user)
            .permit(:password, :password_confirmation, :password_challenge)
            .with_defaults(password_challenge: "")
    end

    def render_user_profile
      render_json({
        user: user_profile_payload(current_resource_owner),
        family: family_profile_payload(current_resource_owner.family),
        options: user_profile_options,
        email_change_requested: @email_change_requested || false
      })
    end

    def user_profile_payload(user)
      {
        id: user.id,
        email: user.email,
        unconfirmed_email: user.unconfirmed_email,
        pending_email_change: user.pending_email_change?,
        first_name: user.first_name,
        last_name: user.last_name,
        display_name: user.display_name,
        initials: user.initials,
        role: user.role,
        active: user.active?,
        locale: user.locale,
        theme: user.theme,
        default_period: user.default_period,
        default_account_order: user.default_account_order,
        show_sidebar: user.show_sidebar?,
        show_ai_sidebar: user.show_ai_sidebar?,
        ai_enabled: user.ai_enabled?,
        ai_available: user.ai_available?,
        rule_prompts_disabled: user.rule_prompts_disabled?,
        rule_prompt_dismissed_at: user.rule_prompt_dismissed_at&.iso8601,
        onboarded_at: user.onboarded_at&.iso8601,
        set_onboarding_preferences_at: user.set_onboarding_preferences_at&.iso8601,
        set_onboarding_goals_at: user.set_onboarding_goals_at&.iso8601,
        goals: user.goals || [],
        default_account_id: user.default_account_id,
        created_at: user.created_at.iso8601,
        updated_at: user.updated_at.iso8601
      }
    end

    def family_profile_payload(family)
      {
        id: family.id,
        name: family.name,
        currency: family.currency,
        locale: family.locale,
        date_format: family.date_format,
        country: family.country,
        timezone: family.timezone,
        month_start_day: family.month_start_day,
        moniker: family.moniker,
        default_account_sharing: family.default_account_sharing,
        custom_enabled_currencies: family.custom_enabled_currencies?,
        enabled_currencies: family.enabled_currency_codes,
        created_at: family.created_at.iso8601,
        updated_at: family.updated_at.iso8601
      }
    end

    def user_profile_options
      {
        default_periods: Period::PERIODS.keys,
        default_account_orders: AccountOrder::ORDERS.keys,
        themes: %w[light dark system],
        locales: I18n.available_locales.map(&:to_s),
        family_sharing_modes: %w[shared private]
      }
    end

    def render_user_validation_error(user, message: "User could not be updated")
      render_json({
        error: "validation_failed",
        message: message,
        errors: user.errors.full_messages
      }, status: :unprocessable_entity)
    end

    def render_family_validation_error(family)
      render_json({
        error: "validation_failed",
        message: "Family settings could not be updated",
        errors: family.errors.full_messages
      }, status: :unprocessable_entity)
    end

    def reset_target_counts(family)
      counts = Family::FinancialDataReset.new(family: family, dry_run: true, confirmed: false).call.before_counts.except(:syncs)

      counts.merge(plaid_items: family.plaid_items.count)
    end
end
