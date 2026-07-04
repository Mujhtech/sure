# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountableSparklinesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
  end

  test "should require authentication" do
    get "/api/v1/accountable_sparklines/depository"

    assert_response :unauthorized
  end

  test "should return account type sparkline series" do
    get "/api/v1/accountable_sparklines/depository",
        params: { period: "last_30_days" },
        headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "depository", response_body["accountable_type"]
    assert response_body.key?("period")
    assert response_body.key?("series")
    assert response_body["series"].key?("values")
    assert response_body["series"]["values"].is_a?(Array)
  end

  test "should return 404 for unknown account type" do
    get "/api/v1/accountable_sparklines/not_real", headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
  end

  test "should reject invalid period" do
    get "/api/v1/accountable_sparklines/depository",
        params: { period: "whenever" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "validation_failed", response_body["error"]
    assert_match "period", response_body["message"]
  end

  test "should reject invalid interval" do
    get "/api/v1/accountable_sparklines/depository",
        params: { interval: "2 hours" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "validation_failed", response_body["error"]
    assert_match "interval", response_body["message"]
  end

  private

    def api_headers(auth)
      { "X-Api-Key" => auth.display_key }
    end
end
