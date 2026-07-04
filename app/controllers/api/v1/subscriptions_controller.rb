# frozen_string_literal: true

class Api::V1::SubscriptionsController < Api::V1::BaseController
  PLANS = %w[monthly annual].freeze
  DEFAULT_PLAN = "annual"

  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: %i[start_trial checkout portal]

  def show
    render_subscription
  end

  def start_trial
    family = current_resource_owner.family

    if self_hosted?
      render_feature_disabled("Trials are not available in self-hosted mode")
      return
    end

    unless trial_available?(family)
      render_json({ error: "trial_already_used", message: "Trial has already been used" }, status: :unprocessable_entity)
      return
    end

    family.start_trial_subscription!
    render_subscription(message: "Trial started")
  end

  def checkout
    family = current_resource_owner.family
    plan = checkout_plan

    if self_hosted?
      render_feature_disabled("Subscriptions are not available in self-hosted mode")
      return
    end

    unless PLANS.include?(plan)
      render_json({ error: "invalid_plan", message: "Plan must be monthly or annual" }, status: :unprocessable_entity)
      return
    end

    if family.subscription&.active?
      render_json({ error: "already_subscribed", message: "Family already has an active subscription" }, status: :unprocessable_entity)
      return
    end

    checkout_session = stripe.create_checkout_session(
      plan: plan,
      family_id: family.id,
      family_email: family.payment_email,
      success_url: success_subscription_url + "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: upgrade_subscription_url
    )

    family.update!(stripe_customer_id: checkout_session.customer_id)

    render_json({
      checkout_url: checkout_session.url,
      subscription: subscription_payload(family),
      options: subscription_options(family)
    }, status: :created)
  rescue StandardError => e
    report_subscription_provider_error(e, action: "checkout")
    render_json({ error: "checkout_unavailable", message: "Checkout session could not be created" }, status: :unprocessable_entity)
  end

  def portal
    family = current_resource_owner.family

    if self_hosted?
      render_feature_disabled("Subscriptions are not available in self-hosted mode")
      return
    end

    unless portal_available?(family)
      render_json({ error: "billing_portal_unavailable", message: "Billing portal is not available for this family" }, status: :unprocessable_entity)
      return
    end

    portal_url = stripe.create_payment_portal_session_url(
      customer_id: family.stripe_customer_id,
      return_url: settings_payment_url
    )

    render_json({
      portal_url: portal_url,
      subscription: subscription_payload(family),
      options: subscription_options(family)
    })
  rescue StandardError => e
    report_subscription_provider_error(e, action: "portal")
    render_json({ error: "billing_portal_unavailable", message: "Billing portal session could not be created" }, status: :unprocessable_entity)
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def checkout_plan
      params[:plan].presence || DEFAULT_PLAN
    end

    def render_subscription(message: nil)
      family = current_resource_owner.family
      payload = {
        subscription: subscription_payload(family),
        options: subscription_options(family)
      }
      payload[:message] = message if message.present?

      render_json(payload)
    end

    def subscription_payload(family)
      subscription = family.subscription
      trial_ends_at = subscription&.trial_ends_at

      {
        self_hosted: self_hosted?,
        upgrade_required: family.upgrade_required?,
        needs_subscription: family.needs_subscription?,
        can_start_trial: trial_available?(family),
        trialing: family.trialing?,
        active: family.has_active_subscription?,
        can_manage_subscription: portal_available?(family),
        status: subscription&.status,
        name: subscription&.name,
        amount: subscription&.amount&.to_s,
        currency: subscription&.currency,
        interval: subscription&.interval,
        trial_ends_at: trial_ends_at&.iso8601,
        current_period_ends_at: subscription&.current_period_ends_at&.iso8601,
        days_left_in_trial: trial_ends_at.present? ? family.days_left_in_trial : nil,
        percentage_of_trial_remaining: trial_ends_at.present? ? family.percentage_of_trial_remaining : nil,
        percentage_of_trial_completed: trial_ends_at.present? ? family.percentage_of_trial_completed : nil,
        pending_cancellation: subscription&.pending_cancellation? || false,
        cancel_at_period_end: subscription&.cancel_at_period_end,
        created_at: subscription&.created_at&.iso8601,
        updated_at: subscription&.updated_at&.iso8601
      }
    end

    def subscription_options(family)
      {
        plans: [
          { key: "monthly", interval: "month" },
          { key: "annual", interval: "year" }
        ],
        default_plan: DEFAULT_PLAN,
        checkout_available: checkout_available?(family),
        portal_available: portal_available?(family)
      }
    end

    def trial_available?(family)
      !self_hosted? && family.subscription.blank? && family.can_start_trial?
    end

    def checkout_available?(family)
      !self_hosted? && !family.subscription&.active?
    end

    def portal_available?(family)
      !self_hosted? && family.can_manage_subscription?
    end

    def render_feature_disabled(message)
      render_json({ error: "feature_disabled", message: message }, status: :forbidden)
    end

    def report_subscription_provider_error(error, action:)
      Rails.logger.error "API Subscription #{action} failed for family #{current_resource_owner.family_id}: #{error.class}: #{error.message}"
      Sentry.capture_exception(error) if defined?(Sentry)
    end

    def stripe
      @stripe ||= Provider::Registry.get_provider(:stripe)
    end
end
