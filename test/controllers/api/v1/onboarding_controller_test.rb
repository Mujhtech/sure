# frozen_string_literal: true

require "test_helper"

class Api::V1::OnboardingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all
    @user.update!(
      first_name: nil,
      last_name: nil,
      set_onboarding_preferences_at: nil,
      set_onboarding_goals_at: nil,
      onboarded_at: nil,
      goals: []
    )

    @read_key = ApiKey.create!(
      user: @user,
      name: "Onboarding Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "onboarding_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "Onboarding Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "onboarding_write_#{SecureRandom.hex(8)}"
    )
  end

  test "show returns onboarding state and options" do
    get api_v1_onboarding_url, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal false, response_data.dig("onboarding", "onboarded")
    assert_equal "profile", response_data.dig("onboarding", "next_step")
    assert_equal "profile", response_data.dig("onboarding", "steps", 0, "key")
    assert_equal false, response_data.dig("onboarding", "steps", 0, "complete")
    assert_equal @user.id, response_data.dig("user", "id")
    assert_equal @family.id, response_data.dig("family", "id")
    assert_includes response_data.dig("options", "themes"), "system"
    assert_includes response_data.dig("options", "monikers"), "Family"
    assert response_data.dig("options", "goals").any? { |goal| goal["value"] == "cashflow" }
  end

  test "show requires authentication" do
    get api_v1_onboarding_url

    assert_response :unauthorized
  end

  test "profile step updates user and family setup for admins" do
    patch profile_api_v1_onboarding_url,
          params: {
            user: { first_name: "Mobile", last_name: "User" },
            family: { name: "Mobile Household", moniker: "Group", country: "US" }
          },
          headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "Mobile", response_data.dig("user", "first_name")
    assert_equal "User", response_data.dig("user", "last_name")
    assert_equal "Mobile Household", response_data.dig("family", "name")
    assert_equal "Group", response_data.dig("family", "moniker")
    assert_equal "preferences", response_data.dig("onboarding", "next_step")
    assert_equal "Mobile", @user.reload.first_name
    assert_equal "Mobile Household", @family.reload.name
  end

  test "profile step rejects family setup for non admins" do
    member = users(:family_member)
    member.api_keys.active.destroy_all
    member_key = ApiKey.create!(
      user: member,
      name: "Member Onboarding Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "onboarding_member_#{SecureRandom.hex(8)}"
    )

    patch profile_api_v1_onboarding_url,
          params: { family: { name: "Blocked" } },
          headers: api_headers(member_key)

    assert_response :forbidden
  end

  test "preferences step updates family preferences and timestamp" do
    patch preferences_api_v1_onboarding_url,
          params: {
            user: { theme: "dark", locale: "en" },
            family: { locale: "en", currency: "EUR", date_format: "%d/%m/%Y" }
          },
          headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "dark", response_data.dig("user", "theme")
    assert_equal "EUR", response_data.dig("family", "currency")
    assert_equal "%d/%m/%Y", response_data.dig("family", "date_format")
    assert response_data.dig("user", "set_onboarding_preferences_at").present?
    assert_equal "goals", response_data.dig("onboarding", "next_step")
  end

  test "goals step stores goals and completes onboarding" do
    patch goals_api_v1_onboarding_url,
          params: { user: { goals: %w[cashflow budgeting] } },
          headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal %w[cashflow budgeting], response_data.dig("user", "goals")
    assert response_data.dig("user", "set_onboarding_goals_at").present?
    assert response_data.dig("user", "onboarded_at").present?
    assert_equal true, response_data.dig("onboarding", "onboarded")
    assert_equal "complete", response_data.dig("onboarding", "next_step")
  end

  test "complete marks onboarding finished" do
    post complete_api_v1_onboarding_url, headers: api_headers(@write_key)

    assert_response :success
    assert_equal true, JSON.parse(response.body).dig("onboarding", "onboarded")
    assert @user.reload.onboarded_at.present?
  end

  test "start trial creates a trial subscription when available" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(false)
    family = Family.create!(name: "Trial Family", currency: "USD", locale: "en", date_format: "%m-%d-%Y")
    user = family.users.create!(
      email: "trial-onboarding@example.com",
      password: user_password_test,
      password_confirmation: user_password_test,
      role: "admin"
    )
    key = ApiKey.create!(
      user: user,
      name: "Trial Onboarding Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "onboarding_trial_#{SecureRandom.hex(8)}"
    )

    assert_difference("Subscription.count", 1) do
      post start_trial_api_v1_onboarding_url, headers: api_headers(key)
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "Trial started", response_data["message"]
    assert_equal "trialing", response_data.dig("subscription", "status")
  end

  test "write endpoints require read write scope" do
    patch profile_api_v1_onboarding_url,
          params: { user: { first_name: "Blocked" } },
          headers: api_headers(@read_key)

    assert_response :forbidden
  end
end
