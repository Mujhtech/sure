# frozen_string_literal: true

require "test_helper"

class Api::V1::ProviderSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Provider::Factory.ensure_adapters_loaded

    @admin = users(:family_admin)
    @member = users(:family_member)
    @admin.api_keys.active.destroy_all
    @member.api_keys.active.destroy_all

    @read_key = api_key_for(@admin, name: "Provider Settings Read Key", scopes: [ "read" ])
    @write_key = api_key_for(@admin, name: "Provider Settings Write Key", scopes: [ "read_write" ])
    @member_key = api_key_for(@member, name: "Provider Settings Member Key", scopes: [ "read_write" ])

    clear_provider_settings
  end

  teardown do
    clear_provider_settings
  end

  test "show lists registered provider settings without leaking secrets" do
    Setting[:plaid_client_id] = "plaid-client-id"
    Setting[:plaid_secret] = "plaid-secret"
    Setting[:plaid_environment] = "development"

    get api_v1_provider_settings_url, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    plaid = response_data["provider_settings"].find { |provider| provider["provider"] == "plaid" }

    assert_not_nil plaid
    assert_equal true, plaid["configured"]
    assert_equal "Plaid", plaid["name"]
    assert_equal "US", plaid.dig("metadata", "region")

    client_id = plaid["fields"].find { |field| field["setting_key"] == "plaid_client_id" }
    secret = plaid["fields"].find { |field| field["setting_key"] == "plaid_secret" }
    environment = plaid["fields"].find { |field| field["setting_key"] == "plaid_environment" }

    assert_equal "plaid-client-id", client_id["value"]
    assert_equal "setting", client_id["value_source"]
    assert_equal true, secret["configured"]
    assert_equal "setting", secret["value_source"]
    assert_equal true, secret["secret"]
    assert_not secret.key?("value")
    assert_equal "development", environment["value"]
    refute_includes response.body, "plaid-secret"
  end

  test "show requires authentication" do
    get api_v1_provider_settings_url

    assert_response :unauthorized
  end

  test "show requires family admin" do
    get api_v1_provider_settings_url, headers: api_headers(@member_key)

    assert_response :forbidden
    assert_equal "Provider settings can only be changed by an admin", JSON.parse(response.body)["message"]
  end

  test "update changes registered settings and ignores redacted secrets" do
    Setting[:plaid_secret] = "previous-secret"

    patch api_v1_provider_settings_url,
          params: {
            setting: {
              plaid_client_id: " new-client-id ",
              plaid_secret: "********",
              plaid_environment: " production ",
              unknown_setting: "ignored"
            }
          },
          headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal "Provider settings updated", response_data["message"]
    assert_includes response_data["updated_fields"], "plaid_client_id"
    assert_includes response_data["updated_fields"], "plaid_environment"
    assert_not_includes response_data["updated_fields"], "plaid_secret"
    assert_equal "new-client-id", Setting[:plaid_client_id]
    assert_equal "previous-secret", Setting[:plaid_secret]
    assert_equal "production", Setting[:plaid_environment]
    refute_includes response.body, "previous-secret"
  end

  test "update accepts provider_settings root" do
    patch api_v1_provider_settings_url,
          params: {
            provider_settings: {
              plaid_client_id: "root-client-id"
            }
          },
          headers: api_headers(@write_key)

    assert_response :success
    assert_equal "root-client-id", Setting[:plaid_client_id]
  end

  test "update requires write scope" do
    patch api_v1_provider_settings_url,
          params: { setting: { plaid_client_id: "blocked" } },
          headers: api_headers(@read_key)

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "update requires family admin" do
    patch api_v1_provider_settings_url,
          params: { setting: { plaid_client_id: "blocked" } },
          headers: api_headers(@member_key)

    assert_response :forbidden
    assert_equal "Provider settings can only be changed by an admin", JSON.parse(response.body)["message"]
  end

  test "update rejects missing settings payload" do
    patch api_v1_provider_settings_url,
          params: {},
          headers: api_headers(@write_key)

    assert_response :bad_request
    assert_equal "bad_request", JSON.parse(response.body)["error"]
  end

  private
    def api_key_for(user, name:, scopes:)
      ApiKey.create!(
        user: user,
        name: name,
        scopes: scopes,
        source: "mobile",
        display_key: "provider_settings_#{SecureRandom.hex(8)}"
      )
    end

    def clear_provider_settings
      Setting[:plaid_client_id] = nil
      Setting[:plaid_secret] = nil
      Setting[:plaid_environment] = nil
      Setting[:plaid_eu_client_id] = nil
      Setting[:plaid_eu_secret] = nil
      Setting[:plaid_eu_environment] = nil
    end
end
