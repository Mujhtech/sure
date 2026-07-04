# frozen_string_literal: true

require "test_helper"

class Api::V1::PreferencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: {})
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )
    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")
  end

  test "shows current preferences" do
    @user.update!(
      preferences: {
        "dashboard_two_column" => true,
        "show_split_grouped" => false,
        "collapsed_sections" => { "balance_sheet" => true }
      }
    )

    get api_v1_preferences_url, headers: api_headers(@read_only_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal true, response_body.dig("preferences", "appearance", "dashboard_two_column")
    assert_equal false, response_body.dig("preferences", "appearance", "show_split_grouped")
    assert_equal true, response_body.dig("preferences", "dashboard", "collapsed_sections", "balance_sheet")
    assert response_body.dig("options", "dashboard_sections").is_a?(Array)
  end

  test "updates nested preferences" do
    patch api_v1_preferences_url,
          params: {
            preferences: {
              preview_features_enabled: true,
              show_split_grouped: false,
              dashboard_two_column: true,
              dashboard: {
                collapsed_sections: { "net_worth_chart" => true },
                section_order: %w[balance_sheet net_worth_chart],
                section_layout: { "net_worth_chart" => { "height" => "tall", "col_span" => "full" } }
              },
              reports: {
                collapsed_sections: { "transactions_breakdown" => true },
                section_order: %w[transactions_breakdown trends_insights]
              },
              transactions: {
                collapsed_sections: { "filters" => true }
              }
            }
          },
          headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal true, response_body.dig("preferences", "preview_features_enabled")
    assert_equal false, response_body.dig("preferences", "appearance", "show_split_grouped")
    assert_equal true, response_body.dig("preferences", "appearance", "dashboard_two_column")
    assert_equal true, response_body.dig("preferences", "dashboard", "collapsed_sections", "net_worth_chart")
    assert_equal "tall", response_body.dig("preferences", "dashboard", "section_layout", "net_worth_chart", "height")
    assert_equal true, response_body.dig("preferences", "reports", "collapsed_sections", "transactions_breakdown")
    assert_equal true, response_body.dig("preferences", "transactions", "collapsed_sections", "filters")

    stored = @user.reload.preferences
    assert_equal true, stored.dig("collapsed_sections", "net_worth_chart")
    assert_equal %w[balance_sheet net_worth_chart], stored["section_order"]
    assert_equal "full", stored.dig("dashboard_section_layout", "net_worth_chart", "col_span")
  end

  test "merges dashboard layout preferences without clobbering siblings" do
    @user.update!(
      preferences: {
        "dashboard_section_layout" => {
          "net_worth_chart" => { "height" => "compact", "col_span" => "single" }
        }
      }
    )

    patch api_v1_preferences_url,
          params: {
            preferences: {
              dashboard: {
                section_layout: {
                  "net_worth_chart" => { "height" => "tall" }
                }
              }
            }
          },
          headers: api_headers(@api_key)

    assert_response :success
    stored_layout = @user.reload.preferences.dig("dashboard_section_layout", "net_worth_chart")
    assert_equal "tall", stored_layout["height"]
    assert_equal "single", stored_layout["col_span"]
  end

  test "rejects preferences update with read only key" do
    patch api_v1_preferences_url,
          params: { preferences: { preview_features_enabled: true } },
          headers: api_headers(@read_only_api_key)

    assert_response :forbidden
    assert_nil @user.reload.preferences["preview_features_enabled"]
  end

  test "requires preferences payload on update" do
    patch api_v1_preferences_url, params: {}, headers: api_headers(@api_key)

    assert_response :bad_request
    response_body = JSON.parse(response.body)
    assert_equal "bad_request", response_body["error"]
  end

  test "requires authentication" do
    get api_v1_preferences_url

    assert_response :unauthorized
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
