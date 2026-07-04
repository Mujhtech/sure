# frozen_string_literal: true

require "test_helper"

class Api::V1::DebugLogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @super_admin = users(:sure_support_staff)
    @family_admin = users(:family_admin)

    @super_admin.api_keys.active.destroy_all
    @family_admin.api_keys.active.destroy_all

    @super_admin_api_key = ApiKey.create!(
      user: @super_admin,
      name: "Debug Logs Read Key",
      scopes: [ "read" ],
      display_key: "debug_ro_#{SecureRandom.hex(8)}"
    )
    @family_admin_api_key = ApiKey.create!(
      user: @family_admin,
      name: "Debug Logs Forbidden Key",
      scopes: [ "read" ],
      display_key: "debug_forbidden_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@super_admin_api_key.id}")
    Redis.new.del("api_rate_limit:#{@family_admin_api_key.id}")

    @entry = DebugLogEntry.create!(
      category: "security_price_fetch",
      level: "warn",
      message: "Could not fetch prices",
      source: "Security::Price::Importer",
      provider_key: "twelve_data",
      family: families(:dylan_family),
      account: accounts(:depository),
      user: @family_admin,
      metadata: { ticker: "AAPL" }
    )

    @other_entry = DebugLogEntry.create!(
      category: "provider_sync",
      level: "info",
      message: "Filtered out",
      source: "Provider::Syncer",
      provider_key: "simplefin",
      family: families(:dylan_family),
      user: @family_admin,
      metadata: { account_count: 2 }
    )
  end

  test "super admin lists debug logs with filters and options" do
    get "/api/v1/debug_logs",
        params: { provider_key: "twelve_data" },
        headers: api_headers(@super_admin_api_key)

    assert_response :success

    response_data = response_body
    assert_equal [ @entry.id ], response_data["debug_logs"].map { |entry| entry["id"] }
    assert_equal "security_price_fetch", response_data.dig("debug_logs", 0, "category")
    assert_equal "AAPL", response_data.dig("debug_logs", 0, "metadata", "ticker")
    assert_equal accounts(:depository).id, response_data.dig("debug_logs", 0, "account", "id")
    assert_includes response_data.dig("filters", "levels"), "warn"
    assert_includes response_data.dig("filters", "provider_keys"), "twelve_data"
    assert_equal 1, response_data.dig("pagination", "total_count")
  end

  test "super admin shows a debug log" do
    get "/api/v1/debug_logs/#{@entry.id}",
        headers: api_headers(@super_admin_api_key)

    assert_response :success

    response_data = response_body
    assert_equal @entry.id, response_data.dig("debug_log", "id")
    assert_equal @entry.message, response_data.dig("debug_log", "message")
    assert_equal @family_admin.email, response_data.dig("debug_log", "user", "email")
  end

  test "non super admins cannot access debug logs" do
    get "/api/v1/debug_logs",
        headers: api_headers(@family_admin_api_key)

    assert_response :forbidden
  end

  test "invalid uuid filters are ignored" do
    get "/api/v1/debug_logs",
        params: { family_id: "not-a-uuid", category: @entry.category },
        headers: api_headers(@super_admin_api_key)

    assert_response :success

    response_data = response_body
    assert_equal [ @entry.id ], response_data["debug_logs"].map { |entry| entry["id"] }
  end

  private

    def response_body
      JSON.parse(response.body)
    end
end
