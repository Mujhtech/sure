# frozen_string_literal: true

require "test_helper"

class Api::V1::Admin::SsoProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    SsoProvider.destroy_all

    @super_admin = users(:sure_support_staff)
    @family_admin = users(:family_admin)

    @super_admin.api_keys.active.destroy_all
    @family_admin.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @super_admin,
      name: "SSO Providers Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "sso_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @super_admin,
      name: "SSO Providers Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "sso_write_#{SecureRandom.hex(8)}"
    )
    @family_admin_key = ApiKey.create!(
      user: @family_admin,
      name: "SSO Providers Forbidden Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "sso_forbidden_#{SecureRandom.hex(8)}"
    )

    Redis.new.del("api_rate_limit:#{@read_key.id}")
    Redis.new.del("api_rate_limit:#{@write_key.id}")
    Redis.new.del("api_rate_limit:#{@family_admin_key.id}")

    @provider = SsoProvider.create!(
      strategy: "google_oauth2",
      name: "google_api",
      label: "Sign in with Google",
      enabled: true,
      client_id: "client-id",
      client_secret: "existing-secret",
      settings: {
        "default_role" => "member",
        "idp_certificate" => "-----BEGIN CERTIFICATE-----"
      }
    )
  end

  test "super admin lists database and legacy runtime providers without secrets" do
    Rails.configuration.x.auth.stubs(:sso_providers).returns([
      { name: "legacy_oidc", label: "Legacy OIDC", icon: "key-round", strategy: "openid_connect", client_secret: "runtime-secret" },
      { name: @provider.name, label: @provider.label, strategy: @provider.strategy }
    ])

    get api_v1_admin_sso_providers_url, headers: api_headers(@read_key)

    assert_response :success

    response_data = response_body
    assert_equal [ @provider.id ], response_data["sso_providers"].map { |provider| provider["id"] }
    assert_equal [ "legacy_oidc" ], response_data["legacy_providers"].map { |provider| provider["name"] }
    assert_equal false, response_data.dig("legacy_providers", 0).key?("client_secret")
    assert_includes response_data.dig("configuration", "supported_strategies"), "openid_connect"
  end

  test "super admin shows provider with client secret and certificate redacted" do
    get api_v1_admin_sso_provider_url(@provider), headers: api_headers(@read_key)

    assert_response :success

    provider = response_body["sso_provider"]
    assert_equal @provider.id, provider["id"]
    assert_equal true, provider["client_secret_present"]
    assert_equal false, provider.key?("client_secret")
    assert_equal true, provider.dig("settings", "idp_certificate_present")
    assert_equal false, provider["settings"].key?("idp_certificate")
  end

  test "super admin creates provider and auto assigns callback redirect uri" do
    assert_difference("SsoProvider.count", 1) do
      post api_v1_admin_sso_providers_url,
           params: {
             sso_provider: {
               strategy: "github",
               name: "github_api",
               label: "GitHub",
               enabled: true,
               client_id: "github-client",
               client_secret: "github-secret",
               settings: { default_role: "member" }
             }
           },
           headers: api_headers(@write_key)
    end

    assert_response :created

    provider = SsoProvider.find_by!(name: "github_api")
    assert_equal "http://www.example.com/auth/github_api/callback", provider.redirect_uri
    assert_equal true, response_body.dig("sso_provider", "client_secret_present")
  end

  test "super admin updates provider and preserves blank client secret" do
    patch api_v1_admin_sso_provider_url(@provider),
          params: {
            sso_provider: {
              label: "Updated Google",
              client_secret: "",
              settings: {
                default_role: "admin",
                role_mapping: {
                  admin: "finance, operations",
                  guest: ""
                }
              }
            }
          },
          headers: api_headers(@write_key)

    assert_response :success

    @provider.reload
    assert_equal "Updated Google", @provider.label
    assert_equal "existing-secret", @provider.client_secret
    assert_equal "admin", @provider.settings["default_role"]
    assert_equal "-----BEGIN CERTIFICATE-----", @provider.settings["idp_certificate"]
    assert_equal [ "finance", "operations" ], @provider.settings.dig("role_mapping", "admin")
    assert_nil @provider.settings.dig("role_mapping", "guest")
  end

  test "super admin toggles provider" do
    patch toggle_api_v1_admin_sso_provider_url(@provider), headers: api_headers(@write_key)

    assert_response :success
    assert_equal false, @provider.reload.enabled?
    assert_equal "SSO provider disabled successfully", response_body["message"]
  end

  test "super admin tests provider connection" do
    post test_connection_api_v1_admin_sso_provider_url(@provider), headers: api_headers(@write_key)

    assert_response :success
    assert_equal true, response_body["success"]
    assert_equal "Google OAuth2 configuration looks valid", response_body["message"]
  end

  test "read only key cannot mutate providers" do
    assert_no_difference("SsoProvider.count") do
      post api_v1_admin_sso_providers_url,
           params: {
             sso_provider: {
               strategy: "github",
               name: "read_only_github",
               label: "GitHub",
               client_id: "github-client",
               client_secret: "github-secret"
             }
           },
           headers: api_headers(@read_key)
    end

    assert_response :forbidden
  end

  test "non super admins cannot access providers" do
    get api_v1_admin_sso_providers_url, headers: api_headers(@family_admin_key)

    assert_response :forbidden
    assert_equal "SSO providers can only be managed by a super admin", response_body["message"]
  end

  test "returns validation errors" do
    assert_no_difference("SsoProvider.count") do
      post api_v1_admin_sso_providers_url,
           params: {
             sso_provider: {
               strategy: "unknown",
               name: "bad_provider",
               label: "Bad Provider"
             }
           },
           headers: api_headers(@write_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response_body["error"]
  end

  test "requires authentication" do
    get api_v1_admin_sso_providers_url

    assert_response :unauthorized
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def response_body
      JSON.parse(response.body)
    end
end
