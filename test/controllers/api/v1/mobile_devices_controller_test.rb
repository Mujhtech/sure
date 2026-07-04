# frozen_string_literal: true

require "test_helper"

class Api::V1::MobileDevicesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_user = users(:empty)
    @user.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @user,
      name: "Mobile Devices Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "mobile_devices_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "Mobile Devices Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "mobile_devices_write_#{SecureRandom.hex(8)}"
    )

    @oauth_app = Doorkeeper::Application.create!(
      name: "Mobile Devices Test App",
      redirect_uri: "sureapp://oauth/callback",
      scopes: "read read_write",
      confidential: false
    )

    @current_device = @user.mobile_devices.create!(
      device_id: "ios-current-#{SecureRandom.hex(4)}",
      device_name: "Muhideen iPhone",
      device_type: "ios",
      os_version: "18.0",
      app_version: "1.4.0",
      last_seen_at: 2.hours.ago
    )
    @older_device = @user.mobile_devices.create!(
      device_id: "ios-old-#{SecureRandom.hex(4)}",
      device_name: "Old iPad",
      device_type: "ios",
      os_version: "17.5",
      app_version: "1.2.0",
      last_seen_at: 4.months.ago
    )
    @other_device = @other_user.mobile_devices.create!(
      device_id: "android-other-#{SecureRandom.hex(4)}",
      device_name: "Other Android",
      device_type: "android",
      os_version: "15",
      app_version: "1.1.0",
      last_seen_at: Time.current
    )

    @current_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      mobile_device_id: @current_device.id,
      scopes: "read_write",
      expires_in: 30.days.to_i
    )
  end

  test "index requires authentication" do
    get api_v1_mobile_devices_url

    assert_response :unauthorized
  end

  test "index lists current user's devices without raw device identifiers" do
    get api_v1_mobile_devices_url, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    devices = response_data["mobile_devices"]
    device_ids = devices.map { |device| device["id"] }

    assert_includes device_ids, @current_device.id
    assert_includes device_ids, @older_device.id
    assert_not_includes device_ids, @other_device.id

    payload = devices.find { |device| device["id"] == @current_device.id }
    assert_equal "Muhideen iPhone", payload["name"]
    assert_equal "ios", payload["device_type"]
    assert_equal "18.0", payload["os_version"]
    assert_equal "1.4.0", payload["app_version"]
    assert_equal true, payload["active"]
    assert_equal false, payload["current"]
    assert_equal 1, payload["active_token_count"]
    assert payload["last_seen_at"].present?
    assert payload["created_at"].present?
    assert payload["updated_at"].present?
    assert_not payload.key?("device_id")
  end

  test "index marks OAuth token mobile device as current" do
    get api_v1_mobile_devices_url, headers: oauth_headers(@current_token)

    assert_response :success
    response_data = JSON.parse(response.body)
    current_payload = response_data["mobile_devices"].find { |device| device["id"] == @current_device.id }
    older_payload = response_data["mobile_devices"].find { |device| device["id"] == @older_device.id }

    assert_equal true, current_payload["current"]
    assert_equal false, older_payload["current"]
  end

  test "show returns a mobile device" do
    get api_v1_mobile_device_url(@current_device), headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @current_device.id, response_data["id"]
    assert_equal "Muhideen iPhone", response_data["name"]
    assert_equal true, response_data["active"]
  end

  test "show returns not found for another user's mobile device" do
    get api_v1_mobile_device_url(@other_device), headers: api_headers(@read_key)

    assert_response :not_found
  end

  test "destroy requires write scope" do
    delete api_v1_mobile_device_url(@current_device), headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "destroy revokes active tokens for the selected mobile device only" do
    other_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      mobile_device_id: @older_device.id,
      scopes: "read_write",
      expires_in: 30.days.to_i
    )

    delete api_v1_mobile_device_url(@current_device), headers: api_headers(@write_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "Mobile device tokens revoked", response_data["message"]
    assert_equal @current_device.id, response_data["mobile_device"]["id"]
    assert_equal 1, response_data["revoked_token_count"]
    assert_equal 0, response_data["mobile_device"]["active_token_count"]

    assert @current_token.reload.revoked?
    assert_not other_token.reload.revoked?
  end

  private
    def oauth_headers(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
