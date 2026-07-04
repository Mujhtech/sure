# frozen_string_literal: true

require "test_helper"

class Api::V1::SecurityControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @user.webauthn_credentials.destroy_all
    @user.update!(otp_required: true, otp_backup_codes: [ "code-one", "code-two" ])

    @api_key = ApiKey.create!(
      user: @user,
      name: "Security Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "security_read_#{SecureRandom.hex(8)}"
    )

    @credential = @user.webauthn_credentials.create!(
      nickname: "MacBook Touch ID",
      credential_id: "credential-#{SecureRandom.hex(8)}",
      public_key: "public-key",
      sign_count: 0,
      transports: [ "internal" ],
      last_used_at: 1.hour.ago
    )
  end

  test "show returns security overview" do
    get api_v1_security_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    security = response_data["security"]

    assert_equal true, security.dig("mfa", "enabled")
    assert_equal true, security.dig("mfa", "webauthn_enabled")
    assert_equal 2, security.dig("mfa", "backup_codes_remaining")
    assert_equal true, security.dig("local_authentication", "password_enabled")
    assert_equal false, security.dig("local_authentication", "sso_only")

    credential_payload = security["webauthn_credentials"].first
    assert_equal @credential.id, credential_payload["id"]
    assert_equal "MacBook Touch ID", credential_payload["nickname"]
    assert_equal [ "internal" ], credential_payload["transports"]
    assert credential_payload["last_used_at"].present?
    assert_not credential_payload.key?("credential_id")
    assert_not credential_payload.key?("public_key")

    identity_payload = security["sso_identities"].find { |identity| identity["provider"] == "openid_connect" }
    assert identity_payload.present?
    assert_equal true, identity_payload["can_unlink"]
    assert identity_payload["email"].present?
  end

  test "show requires authentication" do
    get api_v1_security_url

    assert_response :unauthorized
  end
end
