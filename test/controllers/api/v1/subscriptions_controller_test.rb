# frozen_string_literal: true

require "test_helper"

class Api::V1::SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(false)

    @user = users(:family_admin)
    @family = @user.family
    @family.update!(stripe_customer_id: nil)
    @user.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @user,
      name: "Subscription Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "subscription_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "Subscription Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "subscription_write_#{SecureRandom.hex(8)}"
    )
  end

  test "show returns subscription state and available actions" do
    get api_v1_subscription_url, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    subscription_data = response_data["subscription"]

    assert_equal false, subscription_data["self_hosted"]
    assert_equal true, subscription_data["active"]
    assert_equal "active", subscription_data["status"]
    assert_equal false, subscription_data["can_start_trial"]
    assert_equal false, subscription_data["can_manage_subscription"]
    assert_nil subscription_data["days_left_in_trial"]
    assert_equal "annual", response_data.dig("options", "default_plan")
    assert_equal false, response_data.dig("options", "checkout_available")
    assert_equal false, response_data.dig("options", "portal_available")
    refute_includes subscription_data.keys, "stripe_id"
    refute_includes subscription_data.keys, "stripe_customer_id"
  end

  test "show requires authentication" do
    get api_v1_subscription_url

    assert_response :unauthorized
  end

  test "start trial creates a trial subscription when available" do
    user, key = mobile_user_with_key(email: "trial-subscription@example.com")

    assert_difference("Subscription.count", 1) do
      post start_trial_api_v1_subscription_url, headers: api_headers(key)
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "Trial started", response_data["message"]
    assert_equal "trialing", response_data.dig("subscription", "status")
    assert_equal false, response_data.dig("subscription", "can_start_trial")
    assert_equal "trialing", user.family.reload.subscription.status
  end

  test "start trial rejects families that already have a subscription" do
    post start_trial_api_v1_subscription_url, headers: api_headers(@write_key)

    assert_response :unprocessable_entity
    assert_equal "trial_already_used", JSON.parse(response.body)["error"]
  end

  test "start trial is disabled in self hosted mode" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    _user, key = mobile_user_with_key(email: "self-hosted-trial@example.com")

    post start_trial_api_v1_subscription_url, headers: api_headers(key)

    assert_response :forbidden
    assert_equal "feature_disabled", JSON.parse(response.body)["error"]
  end

  test "checkout creates a Stripe checkout session and stores customer id" do
    user, key = mobile_user_with_key(email: "checkout-subscription@example.com")
    checkout_session = Struct.new(:url, :customer_id).new("https://checkout.example/session", "cus_mobile_123")
    stripe = mock("stripe")
    stripe.expects(:create_checkout_session).returns(checkout_session)
    Provider::Registry.stubs(:get_provider).with(:stripe).returns(stripe)

    post checkout_api_v1_subscription_url,
         params: { plan: "annual" },
         headers: api_headers(key)

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal "https://checkout.example/session", response_data["checkout_url"]
    assert_equal "cus_mobile_123", user.family.reload.stripe_customer_id
    assert_equal true, response_data.dig("options", "portal_available")
    refute response_data.key?("customer_id")
  end

  test "checkout defaults to annual plan" do
    _user, key = mobile_user_with_key(email: "default-checkout@example.com")
    checkout_session = Struct.new(:url, :customer_id).new("https://checkout.example/default", "cus_default")
    stripe = Class.new do
      attr_reader :plan

      define_method(:initialize) do |session|
        @session = session
      end

      define_method(:create_checkout_session) do |plan:, family_id:, family_email:, success_url:, cancel_url:|
        @plan = plan
        @session
      end
    end.new(checkout_session)
    Provider::Registry.stubs(:get_provider).with(:stripe).returns(stripe)

    post checkout_api_v1_subscription_url, headers: api_headers(key)

    assert_response :created
    assert_equal "annual", stripe.plan
  end

  test "checkout rejects invalid plans" do
    Provider::Registry.expects(:get_provider).never

    post checkout_api_v1_subscription_url,
         params: { plan: "lifetime" },
         headers: api_headers(@write_key)

    assert_response :unprocessable_entity
    assert_equal "invalid_plan", JSON.parse(response.body)["error"]
  end

  test "checkout rejects active subscriptions" do
    Provider::Registry.expects(:get_provider).never

    post checkout_api_v1_subscription_url,
         params: { plan: "annual" },
         headers: api_headers(@write_key)

    assert_response :unprocessable_entity
    assert_equal "already_subscribed", JSON.parse(response.body)["error"]
  end

  test "portal returns a billing portal url" do
    @family.update!(stripe_customer_id: "cus_portal_123")
    stripe = mock("stripe")
    stripe.expects(:create_payment_portal_session_url).returns("https://billing.example/session")
    Provider::Registry.stubs(:get_provider).with(:stripe).returns(stripe)

    post portal_api_v1_subscription_url, headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "https://billing.example/session", response_data["portal_url"]
    assert_equal true, response_data.dig("subscription", "can_manage_subscription")
    assert_equal true, response_data.dig("options", "portal_available")
  end

  test "portal requires a Stripe customer id" do
    Provider::Registry.expects(:get_provider).never

    post portal_api_v1_subscription_url, headers: api_headers(@write_key)

    assert_response :unprocessable_entity
    assert_equal "billing_portal_unavailable", JSON.parse(response.body)["error"]
  end

  test "write endpoints require read write scope" do
    post checkout_api_v1_subscription_url, headers: api_headers(@read_key)

    assert_response :forbidden
  end

  private
    def mobile_user_with_key(email:)
      family = Family.create!(
        name: "Mobile Subscription Family",
        currency: "USD",
        locale: "en",
        date_format: "%m-%d-%Y"
      )
      user = family.users.create!(
        email: email,
        password: user_password_test,
        password_confirmation: user_password_test,
        role: "admin",
        onboarded_at: Time.current
      )
      key = ApiKey.create!(
        user: user,
        name: "Mobile Subscription Key",
        scopes: [ "read_write" ],
        source: "mobile",
        display_key: "subscription_mobile_#{SecureRandom.hex(8)}"
      )

      [ user, key ]
    end
end
