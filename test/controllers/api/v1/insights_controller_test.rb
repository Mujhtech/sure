# frozen_string_literal: true

require "test_helper"

class Api::V1::InsightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @insight = insights(:spending_anomaly_dining)
    @insight.update!(metadata: @insight.metadata.merge("category_id" => @user.family.categories.first.id))
    @user.api_keys.active.destroy_all
    @read_key = create_api_key("read")
    @write_key = create_api_key("read_write")
  end

  test "index returns visible insights and marks active insights read" do
    get "/api/v1/insights", headers: api_headers(@read_key)

    assert_response :success
    data = JSON.parse(response.body)
    item = data.fetch("insights").find { |insight| insight["id"] == @insight.id }

    assert_equal true, item["unread"]
    assert_equal "activity", item["icon"]
    assert_equal "warning", item["sentiment"]
    assert_equal "transactions", item.dig("action", "route")
    assert @insight.reload.read?
  end

  test "preview access is required" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get "/api/v1/insights", headers: api_headers(@read_key)

    assert_response :forbidden
    assert_equal "preview_feature_disabled", JSON.parse(response.body)["error"]
  end

  test "dashboard previews preserve unread state" do
    get "/api/v1/insights", params: { mark_read: false }, headers: api_headers(@read_key)

    assert_response :success
    assert @insight.reload.active?
  end

  test "dismiss and undismiss are family scoped" do
    patch "/api/v1/insights/#{@insight.id}/dismiss", headers: api_headers(@write_key)

    assert_response :success
    assert @insight.reload.dismissed?

    patch "/api/v1/insights/#{@insight.id}/undismiss", headers: api_headers(@write_key)

    assert_response :success
    assert @insight.reload.read?
  end

  test "dismiss requires write scope" do
    patch "/api/v1/insights/#{@insight.id}/dismiss", headers: api_headers(@read_key)

    assert_response :forbidden
    assert @insight.reload.active?
  end

  test "refresh queues generation" do
    assert_enqueued_with(job: GenerateInsightsJob, args: [ { family_id: @user.family_id } ]) do
      post "/api/v1/insights/refresh", headers: api_headers(@write_key)
    end

    assert_response :accepted
  end

  private
    def create_api_key(scope)
      ApiKey.create!(
        user: @user,
        name: "Insights #{scope}",
        scopes: [ scope ],
        display_key: "insights_#{scope}_#{SecureRandom.hex(8)}",
        source: "mobile"
      )
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
