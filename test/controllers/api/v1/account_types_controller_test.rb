# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountTypesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_read_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    @read_write_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_write_key.id}")
  end

  test "requires authentication" do
    get "/api/v1/account_types"

    assert_response :unauthorized
  end

  test "lists account type metadata for mobile forms" do
    get "/api/v1/account_types", headers: api_headers(@api_key)

    assert_response :success

    data = JSON.parse(response.body)["data"]
    assert_equal Accountable::TYPES, data.map { |account_type| account_type["type"] }

    depository = data.detect { |account_type| account_type["type"] == "Depository" }
    assert_equal "depository", depository["key"]
    assert_equal "asset", depository["classification"]
    assert_equal "up", depository["favorable_direction"]
    assert_equal "landmark", depository["icon"]
    assert_equal Depository::DEFAULT_SUBTYPE, depository["default_subtype"]
    assert_includes depository["subtypes"].map { |subtype| subtype["key"] }, "checking"
    assert_kind_of Array, depository["provider_connections"]

    credit_card = data.detect { |account_type| account_type["type"] == "CreditCard" }
    assert_equal "liability", credit_card["classification"]
    assert_equal "down", credit_card["favorable_direction"]

    investment = data.detect { |account_type| account_type["type"] == "Investment" }
    brokerage = investment["subtypes"].detect { |subtype| subtype["key"] == "brokerage" }
    assert_equal "taxable", brokerage["tax_treatment"]

    property = data.detect { |account_type| account_type["type"] == "Property" }
    assert_equal "market value", property["balance_display_name"]
    assert_includes property["subtypes"].map { |subtype| subtype["key"] }, "single_family_home"
  end

  test "read_write key can list account type metadata" do
    get "/api/v1/account_types", headers: api_headers(@read_write_key)

    assert_response :success
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
