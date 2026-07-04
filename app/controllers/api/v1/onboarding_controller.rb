# frozen_string_literal: true

class Api::V1::OnboardingController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: %i[profile preferences goals start_trial complete]

  GOAL_OPTIONS = [
    { icon: "layers", value: "unified_accounts", label_key: "unified_accounts" },
    { icon: "banknote", value: "cashflow", label_key: "cashflow" },
    { icon: "pie-chart", value: "budgeting", label_key: "budgeting" },
    { icon: "users", value: "partner", label_key: "partner" },
    { icon: "area-chart", value: "investments", label_key: "investments" },
    { icon: "bot", value: "ai_insights", label_key: "ai_insights" },
    { icon: "settings-2", value: "optimization", label_key: "optimization" },
    { icon: "frown", value: "reduce_stress", label_key: "reduce_stress" }
  ].freeze

  def show
    render_onboarding
  end

  def profile
    user = current_resource_owner
    family_attrs = profile_family_params

    if family_attrs.present? && !user.admin?
      render_json({ error: "forbidden", message: "Family setup can only be changed by an admin" }, status: :forbidden)
      return
    end

    update_onboarding(user, user_attrs: profile_user_params, family_attrs: family_attrs)
  end

  def preferences
    user = current_resource_owner

    update_onboarding(
      user,
      user_attrs: preferences_user_params.merge(set_onboarding_preferences_at: Time.current),
      family_attrs: preferences_family_params
    )
  end

  def goals
    update_onboarding(
      current_resource_owner,
      user_attrs: {
        goals: Array(goals_params[:goals]).reject(&:blank?),
        set_onboarding_goals_at: Time.current,
        onboarded_at: Time.current
      }
    )
  end

  def complete
    update_onboarding(
      current_resource_owner,
      user_attrs: { onboarded_at: Time.current }
    )
  end

  def start_trial
    family = current_resource_owner.family

    if self_hosted?
      render_json({ error: "feature_disabled", message: "Trials are not available in self-hosted mode" }, status: :forbidden)
      return
    end

    unless trial_available?(family)
      render_json({ error: "trial_already_used", message: "Trial has already been used" }, status: :unprocessable_entity)
      return
    end

    family.start_trial_subscription!
    render_onboarding(message: "Trial started")
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def update_onboarding(user, user_attrs:, family_attrs: {})
      User.transaction do
        if family_attrs.present? && !user.family.update(family_attrs)
          render_family_validation_error(user.family)
          raise ActiveRecord::Rollback
        end

        if user_attrs.present? && !user.update(user_attrs)
          render_user_validation_error(user)
          raise ActiveRecord::Rollback
        end
      end

      render_onboarding unless performed?
    end

    def profile_user_params
      params.fetch(:user, ActionController::Parameters.new)
            .permit(:first_name, :last_name)
    end

    def profile_family_params
      params.fetch(:family, ActionController::Parameters.new)
            .permit(:name, :country, :moniker)
    end

    def preferences_user_params
      params.fetch(:user, ActionController::Parameters.new)
            .permit(:theme, :locale)
    end

    def preferences_family_params
      params.fetch(:family, ActionController::Parameters.new)
            .permit(:locale, :currency, :date_format)
    end

    def goals_params
      params.fetch(:user, ActionController::Parameters.new)
            .permit(goals: [])
    end

    def render_onboarding(message: nil)
      payload = onboarding_payload(current_resource_owner)
      payload[:message] = message if message.present?
      render_json(payload)
    end

    def onboarding_payload(user)
      {
        onboarding: {
          onboarded: user.onboarded?,
          next_step: next_step_for(user),
          steps: onboarding_steps(user),
          invitation: onboarding_invitation_payload(user)
        },
        user: onboarding_user_payload(user),
        family: onboarding_family_payload(user.family),
        subscription: subscription_payload(user.family),
        options: onboarding_options
      }
    end

    def onboarding_steps(user)
      [
        { key: "profile", complete: onboarding_profile_complete?(user) },
        { key: "preferences", complete: user.set_onboarding_preferences_at.present? },
        { key: "goals", complete: user.set_onboarding_goals_at.present? },
        { key: "start", complete: user.onboarded? }
      ]
    end

    def next_step_for(user)
      return "complete" if user.onboarded?
      return "profile" unless onboarding_profile_complete?(user)
      return "preferences" unless user.set_onboarding_preferences_at.present?
      return "goals" unless user.set_onboarding_goals_at.present?
      self_hosted? ? "complete" : "trial"
    end

    def onboarding_profile_complete?(user)
      user.first_name.present? &&
        user.last_name.present? &&
        user.family.country.present?
    end

    def onboarding_user_payload(user)
      {
        id: user.id,
        email: user.email,
        first_name: user.first_name,
        last_name: user.last_name,
        display_name: user.display_name,
        locale: user.locale,
        theme: user.theme,
        goals: user.goals || [],
        onboarded_at: user.onboarded_at&.iso8601,
        set_onboarding_preferences_at: user.set_onboarding_preferences_at&.iso8601,
        set_onboarding_goals_at: user.set_onboarding_goals_at&.iso8601
      }
    end

    def onboarding_family_payload(family)
      {
        id: family.id,
        name: family.name,
        country: family.country,
        moniker: family.moniker,
        currency: family.currency,
        locale: family.locale,
        date_format: family.date_format
      }
    end

    def onboarding_invitation_payload(user)
      invitation = user.family.invitations.accepted.find_by(email: user.email)

      return { accepted: false } unless invitation

      {
        accepted: true,
        id: invitation.id,
        inviter_id: invitation.inviter_id,
        accepted_at: invitation.accepted_at&.iso8601
      }
    end

    def subscription_payload(family)
      subscription = family.subscription

      {
        self_hosted: self_hosted?,
        can_start_trial: trial_available?(family),
        needs_subscription: family.needs_subscription?,
        status: subscription&.status,
        trialing: family.trialing?,
        trial_ends_at: subscription&.trial_ends_at&.iso8601,
        days_left_in_trial: subscription ? family.days_left_in_trial : nil
      }
    end

    def trial_available?(family)
      !self_hosted? && family.subscription.blank? && family.can_start_trial?
    end

    def onboarding_options
      {
        themes: %w[system light dark],
        locales: I18n.available_locales.map(&:to_s),
        currencies: Money::Currency.as_options.map do |currency|
          { code: currency.iso_code, name: currency.name, symbol: currency.symbol }
        end,
        date_formats: Family::DATE_FORMATS.map do |label, value|
          { label: label, value: value }
        end,
        monikers: Family::MONIKERS,
        countries: LanguagesHelper::COUNTRY_MAPPING.keys.map do |code|
          { code: code.to_s, name: LanguagesHelper::COUNTRY_MAPPING[code].to_s.split(" ", 2).last }
        end,
        goals: GOAL_OPTIONS.map do |goal|
          {
            value: goal[:value],
            icon: goal[:icon],
            label: I18n.t("onboardings.goals.#{goal[:label_key]}")
          }
        end
      }
    end

    def render_user_validation_error(user)
      render_json({
        error: "validation_failed",
        message: "Onboarding user settings could not be updated",
        errors: user.errors.full_messages
      }, status: :unprocessable_entity)
    end

    def render_family_validation_error(family)
      render_json({
        error: "validation_failed",
        message: "Onboarding family settings could not be updated",
        errors: family.errors.full_messages
      }, status: :unprocessable_entity)
    end
end
