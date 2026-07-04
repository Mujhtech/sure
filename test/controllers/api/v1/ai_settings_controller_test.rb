# frozen_string_literal: true

require "test_helper"

class Api::V1::AiSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(false)

    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @user.update!(ai_enabled: true, show_ai_sidebar: true)

    @read_key = ApiKey.create!(
      user: @user,
      name: "AI Settings Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "ai_settings_read_#{SecureRandom.hex(8)}"
    )
  end

  test "show returns AI availability, prompt configuration, and function list" do
    get api_v1_ai_settings_url, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal true, response_data.dig("ai", "enabled")
    assert_equal true, response_data.dig("ai", "available")
    assert_equal "builtin", response_data.dig("ai", "assistant_type")
    assert response_data.dig("ai", "default_model").present?
    assert_includes response_data.dig("ai", "available_assistant_types"), "builtin"
    assert response_data["prompts"].any? { |prompt| prompt["key"] == "main_system_prompt" && prompt["instructions"].present? }
    assert response_data["prompts"].any? { |prompt| prompt["key"] == "transaction_categorizer" && prompt["instructions"].present? }
    assert response_data["prompts"].any? { |prompt| prompt["key"] == "merchant_detector" && prompt["instructions"].present? }
    assert response_data["functions"].any? { |function| function["key"] == "get_transactions" }
    refute_includes response.body, "openai_access_token"
    refute_includes response.body, "external_assistant_token"
  end

  test "show reports requested AI state separately from effective availability" do
    @user.update!(ai_enabled: false)

    get api_v1_ai_settings_url, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal false, response_data.dig("ai", "requested_enabled")
    assert_equal false, response_data.dig("ai", "enabled")
    assert_equal true, response_data.dig("ai", "available")
  end

  test "show requires authentication" do
    get api_v1_ai_settings_url

    assert_response :unauthorized
  end
end
