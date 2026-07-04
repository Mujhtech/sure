# frozen_string_literal: true

require "test_helper"
require "webauthn/fake_client"

class Api::V1::WebauthnCredentialsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @user.webauthn_credentials.destroy_all
    @user.update!(otp_required: true)

    @read_key = ApiKey.create!(
      user: @user,
      name: "WebAuthn Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "webauthn_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "WebAuthn Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "webauthn_write_#{SecureRandom.hex(8)}"
    )
    @credential = @user.webauthn_credentials.create!(
      nickname: "Security Key",
      credential_id: "credential-#{SecureRandom.hex(8)}",
      public_key: "public-key",
      sign_count: 0,
      transports: [ "usb" ]
    )
    @client = WebAuthn::FakeClient.new("http://www.example.com")
  end

  test "options returns registration options and stores a short lived challenge" do
    post options_api_v1_webauthn_credentials_url, headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    public_key = response_data["public_key"]

    assert response_data["challenge_id"].present?
    assert_equal 300, response_data["expires_in_seconds"]
    assert public_key["challenge"].present?
    assert_equal @user.email, public_key.dig("user", "name")
    assert_equal @user.display_name, public_key.dig("user", "displayName")
    assert public_key["excludeCredentials"].any? { |credential| credential["id"] == @credential.credential_id }
    assert @user.reload.webauthn_id.present?
  end

  test "create registers a WebAuthn credential from a verified registration challenge" do
    response_data = registration_options
    public_key = response_data.fetch("public_key")
    credential = @client.create(challenge: public_key.fetch("challenge"), rp_id: "www.example.com")

    assert_difference -> { @user.webauthn_credentials.count }, 1 do
      post api_v1_webauthn_credentials_url,
           params: {
             challenge_id: response_data.fetch("challenge_id"),
             webauthn_credential: { nickname: "iPhone Passkey" },
             credential: credential
           },
           headers: api_headers(@write_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    stored_credential = @user.webauthn_credentials.reload.last
    assert_equal "WebAuthn credential registered", response_data["message"]
    assert_equal stored_credential.id, response_data.dig("webauthn_credential", "id")
    assert_equal "iPhone Passkey", response_data.dig("webauthn_credential", "nickname")
    assert_equal credential.fetch("id"), stored_credential.credential_id
    assert_includes stored_credential.transports, "internal"
    refute response_data["webauthn_credential"].key?("credential_id")
    refute response_data["webauthn_credential"].key?("public_key")
  end

  test "create rejects reused registration challenges" do
    response_data = registration_options
    public_key = response_data.fetch("public_key")
    credential = @client.create(challenge: public_key.fetch("challenge"), rp_id: "www.example.com")

    post api_v1_webauthn_credentials_url,
         params: {
           challenge_id: response_data.fetch("challenge_id"),
           webauthn_credential: { nickname: "iPhone Passkey" },
           credential: credential
         },
         headers: api_headers(@write_key)
    assert_response :created

    assert_no_difference -> { @user.webauthn_credentials.count } do
      post api_v1_webauthn_credentials_url,
           params: {
             challenge_id: response_data.fetch("challenge_id"),
             webauthn_credential: { nickname: "Replay" },
             credential: credential
           },
           headers: api_headers(@write_key)
    end

    assert_response :unprocessable_entity
    assert_equal "webauthn_challenge_expired", JSON.parse(response.body)["error"]
  end

  test "create requires a live registration challenge" do
    assert_no_difference -> { @user.webauthn_credentials.count } do
      post api_v1_webauthn_credentials_url,
           params: { challenge_id: SecureRandom.uuid, credential: {} },
           headers: api_headers(@write_key)
    end

    assert_response :unprocessable_entity
    assert_equal "webauthn_challenge_expired", JSON.parse(response.body)["error"]
  end

  test "options requires write scope" do
    post options_api_v1_webauthn_credentials_url, headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "options requires MFA to be enabled" do
    @user.update!(otp_required: false)

    post options_api_v1_webauthn_credentials_url, headers: api_headers(@write_key)

    assert_response :forbidden
    assert_equal "mfa_required", JSON.parse(response.body)["error"]
  end

  test "destroy removes a WebAuthn credential" do
    assert_difference -> { @user.webauthn_credentials.count }, -1 do
      delete api_v1_webauthn_credential_url(@credential), headers: api_headers(@write_key)
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "WebAuthn credential removed", response_data["message"]
    assert_equal @credential.id, response_data["webauthn_credential_id"]
  end

  test "destroy requires write scope" do
    delete api_v1_webauthn_credential_url(@credential), headers: api_headers(@read_key)

    assert_response :forbidden
    assert @user.webauthn_credentials.exists?(@credential.id)
  end

  test "destroy requires MFA to be enabled" do
    @user.update!(otp_required: false)

    delete api_v1_webauthn_credential_url(@credential), headers: api_headers(@write_key)

    assert_response :forbidden
    assert_equal "mfa_required", JSON.parse(response.body)["error"]
  end

  test "destroy returns not found for another user's credential" do
    other_user = users(:empty)
    other_credential = other_user.webauthn_credentials.create!(
      nickname: "Other Key",
      credential_id: "credential-#{SecureRandom.hex(8)}",
      public_key: "public-key",
      sign_count: 0
    )

    delete api_v1_webauthn_credential_url(other_credential), headers: api_headers(@write_key)

    assert_response :not_found
  end

  private
    def registration_options
      post options_api_v1_webauthn_credentials_url, headers: api_headers(@write_key)
      assert_response :success
      JSON.parse(response.body)
    end
end
