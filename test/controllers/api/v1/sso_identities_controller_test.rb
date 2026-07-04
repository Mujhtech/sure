# frozen_string_literal: true

require "test_helper"

class Api::V1::SsoIdentitiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @user,
      name: "SSO Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "sso_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "SSO Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "sso_write_#{SecureRandom.hex(8)}"
    )
    @identity = oidc_identities(:bob_google)
  end

  test "destroy unlinks an SSO identity and writes audit log" do
    assert_difference("SsoAuditLog.count", 1) do
      assert_difference -> { @user.oidc_identities.count }, -1 do
        delete api_v1_sso_identity_url(@identity), headers: api_headers(@write_key)
      end
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "SSO identity unlinked", response_data["message"]
    assert_equal @identity.id, response_data["sso_identity_id"]
    assert_equal "openid_connect", response_data["provider"]
  end

  test "destroy requires write scope" do
    delete api_v1_sso_identity_url(@identity), headers: api_headers(@read_key)

    assert_response :forbidden
    assert @user.oidc_identities.exists?(@identity.id)
  end

  test "destroy prevents unlinking the last identity for an SSO-only user" do
    sso_only_user = users(:sso_only)
    sso_only_user.api_keys.active.destroy_all
    key = ApiKey.create!(
      user: sso_only_user,
      name: "SSO Only Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "sso_only_write_#{SecureRandom.hex(8)}"
    )
    identity = oidc_identities(:sso_only_identity)

    delete api_v1_sso_identity_url(identity), headers: api_headers(key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "cannot_unlink_last_identity", response_data["error"]
    assert sso_only_user.oidc_identities.exists?(identity.id)
  end

  test "destroy returns not found for another user's identity" do
    other_identity = oidc_identities(:jakob_google)

    delete api_v1_sso_identity_url(other_identity), headers: api_headers(@write_key)

    assert_response :not_found
  end
end
