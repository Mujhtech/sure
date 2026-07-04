# frozen_string_literal: true

require "test_helper"

class Api::V1::FamilySettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.update!(
      currency: "SGD",
      enabled_currencies: [ "USD" ],
      locale: "en",
      date_format: "%Y-%m-%d",
      country: "SG",
      timezone: "Asia/Singapore",
      month_start_day: 15,
      moniker: "Family",
      default_account_sharing: "private"
    )

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )
    @read_write_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )
    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_write_api_key.id}")
  end

  test "shows current family settings snapshot" do
    get api_v1_family_settings_url, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert_equal @family.id, response_body["id"]
    assert_equal @family.name, response_body["name"]
    assert_equal "SGD", response_body["currency"]
    assert_equal "en", response_body["locale"]
    assert_equal "%Y-%m-%d", response_body["date_format"]
    assert_equal "SG", response_body["country"]
    assert_equal "Asia/Singapore", response_body["timezone"]
    assert_equal 15, response_body["month_start_day"]
    assert_equal "Family", response_body["moniker"]
    assert_equal "private", response_body["default_account_sharing"]
    assert_equal true, response_body["custom_enabled_currencies"]
    assert_equal @family.enabled_currency_codes, response_body["enabled_currencies"]
    assert_equal @family.created_at.iso8601, response_body["created_at"]
    assert_equal @family.updated_at.iso8601, response_body["updated_at"]
    assert_not response_body.key?("stripe_customer_id")
    assert_not response_body.key?("vector_store_id")
  end

  test "requires authentication" do
    get api_v1_family_settings_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_family_settings_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  test "updates family settings with read write key" do
    patch api_v1_family_settings_url,
          params: {
            family: {
              name: "Mobile Family",
              month_start_day: 7,
              moniker: "Group",
              default_account_sharing: "shared",
              enabled_currencies: %w[USD EUR]
            }
          },
          headers: api_headers(@read_write_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "Mobile Family", response_body["name"]
    assert_equal 7, response_body["month_start_day"]
    assert_equal "Group", response_body["moniker"]
    assert_equal "shared", response_body["default_account_sharing"]
    assert_equal "Mobile Family", @family.reload.name
    assert_equal %w[USD EUR], @family.enabled_currencies
  end

  test "rejects family settings update with read only key" do
    patch api_v1_family_settings_url,
          params: { family: { name: "Nope" } },
          headers: api_headers(@api_key)

    assert_response :forbidden
    assert_not_equal "Nope", @family.reload.name
  end

  test "rejects invalid family settings update" do
    patch api_v1_family_settings_url,
          params: { family: { month_start_day: 99 } },
          headers: api_headers(@read_write_api_key)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "validation_failed", response_body["error"]
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
