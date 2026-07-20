# frozen_string_literal: true

require "test_helper"

class AppleAppSiteAssociationsControllerTest < ActionDispatch::IntegrationTest
  test "serves the savings challenge universal-link association" do
    get "/.well-known/apple-app-site-association"

    assert_response :success
    response_data = JSON.parse(response.body)
    detail = response_data.dig("applinks", "details").first
    assert_includes detail["appIDs"], "6JR3ZGLPD6.mujhtech.usemoney"
    assert_includes detail["components"].map { |component| component["/"] },
                    "/events/30-day-savings-challenge"
  end
end
