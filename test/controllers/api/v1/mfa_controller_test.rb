# frozen_string_literal: true

require "test_helper"

class Api::V1::MfaControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_member)
    @user.disable_mfa!
    @user.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @user,
      name: "MFA Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "mfa_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "MFA Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "mfa_write_#{SecureRandom.hex(8)}"
    )
  end

  test "show returns MFA state without secrets" do
    get api_v1_mfa_url, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal false, response_data.dig("mfa", "enabled")
    assert_equal false, response_data.dig("mfa", "setup_pending")
    assert_equal false, response_data.dig("mfa", "webauthn_enabled")
    assert_equal 0, response_data.dig("mfa", "backup_codes_remaining")
    refute_includes response.body, "otp_secret"
    refute_includes response.body, "otp_backup_codes"
  end

  test "setup prepares TOTP enrollment and returns provisioning data" do
    post setup_api_v1_mfa_url, headers: api_headers(@write_key)

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal true, response_data.dig("mfa", "setup_pending")
    assert_equal false, response_data.dig("mfa", "enabled")
    assert_equal "Sure Finances", response_data.dig("setup", "issuer")
    assert_equal @user.email, response_data.dig("setup", "account_name")
    assert response_data.dig("setup", "otp_secret").present?
    assert_includes response_data.dig("setup", "provisioning_uri"), "otpauth://totp"
    assert_equal response_data.dig("setup", "otp_secret"), @user.reload.otp_secret
    assert_not @user.otp_required?
  end

  test "verify enables MFA with a valid code and returns backup codes once" do
    post setup_api_v1_mfa_url, headers: api_headers(@write_key)
    secret = JSON.parse(response.body).dig("setup", "otp_secret")
    code = ROTP::TOTP.new(secret, issuer: "Sure Finances").now

    post verify_api_v1_mfa_url,
         params: { code: code },
         headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    backup_codes = response_data["backup_codes"]

    assert_equal "MFA enabled", response_data["message"]
    assert_equal true, response_data.dig("mfa", "enabled")
    assert_equal false, response_data.dig("mfa", "setup_pending")
    assert_equal 8, backup_codes.length
    assert backup_codes.all? { |backup_code| backup_code.match?(/\A[0-9a-f]{16}\z/) }
    assert @user.reload.otp_required?
    assert_equal 8, @user.otp_backup_codes.length
    assert_empty backup_codes & @user.otp_backup_codes
    refute_includes response.body, @user.otp_backup_codes.first
  end

  test "verify rejects invalid setup code and clears pending MFA setup" do
    post setup_api_v1_mfa_url, headers: api_headers(@write_key)

    post verify_api_v1_mfa_url,
         params: { code: "invalid" },
         headers: api_headers(@write_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "invalid_code", response_data["error"]
    assert_nil @user.reload.otp_secret
    assert_not @user.otp_required?
    assert_empty @user.otp_backup_codes
  end

  test "setup rejects already enabled MFA" do
    @user.setup_mfa!
    @user.enable_mfa!

    post setup_api_v1_mfa_url, headers: api_headers(@write_key)

    assert_response :unprocessable_entity
    assert_equal "mfa_already_enabled", JSON.parse(response.body)["error"]
  end

  test "destroy disables MFA and removes WebAuthn credentials" do
    @user.setup_mfa!
    @user.enable_mfa!
    @user.webauthn_credentials.create!(
      nickname: "Phone",
      credential_id: "credential_#{SecureRandom.hex(8)}",
      public_key: "public-key",
      sign_count: 0
    )

    delete api_v1_mfa_url, headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "MFA disabled", response_data["message"]
    assert_equal false, response_data.dig("mfa", "enabled")
    assert_nil @user.reload.otp_secret
    assert_empty @user.otp_backup_codes
    assert_empty @user.webauthn_credentials
  end

  test "write endpoints require read write scope" do
    post setup_api_v1_mfa_url, headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "show requires authentication" do
    get api_v1_mfa_url

    assert_response :unauthorized
  end
end
