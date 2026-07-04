# frozen_string_literal: true

require "test_helper"

class Api::V1::AppInfoControllerTest < ActionDispatch::IntegrationTest
  test "shows public app info without authentication" do
    get "/api/v1/app_info"

    assert_response :success
    response_data = response_body

    assert_equal Rails.configuration.x.product_name, response_data.dig("app", "name")
    assert_equal Rails.application.config.app_mode.to_s, response_data.dig("app", "mode")
    assert_includes response_data.dig("legal", "privacy", "url"), "/privacy"
    assert_includes response_data.dig("legal", "terms", "url"), "/terms"
    assert_equal "/api/v1/app_info/changelog", response_data.dig("links", "changelog")
    assert_equal "/api/v1/app_info/feedback", response_data.dig("links", "feedback")
  end

  test "shows public changelog release notes" do
    github_provider = mock
    github_provider.expects(:fetch_latest_release_notes).returns(
      avatar: "https://example.com/avatar.png",
      username: "release-user",
      name: "Mobile API Release",
      published_at: Time.zone.parse("2026-06-01 12:00:00 UTC"),
      body: "<p>New mobile APIs.</p>"
    )
    Provider::Registry.stubs(:get_provider).with(:github).returns(github_provider)

    get "/api/v1/app_info/changelog"

    assert_response :success
    release = response_body["release"]

    assert_equal "Mobile API Release", release["name"]
    assert_equal "release-user", release["username"]
    assert_equal "https://github.com/release-user", release["author_url"]
    assert_equal "https://example.com/avatar.png", release["avatar_url"]
    assert_equal "2026-06-01T12:00:00Z", release["published_at"]
    assert_equal "<p>New mobile APIs.</p>", release["body_html"]
  end

  test "falls back when changelog release notes are unavailable" do
    Provider::Registry.stubs(:get_provider).with(:github).returns(stub(fetch_latest_release_notes: nil))

    get "/api/v1/app_info/changelog"

    assert_response :success
    release = response_body["release"]

    assert_equal "Release notes unavailable", release["name"]
    assert_equal "we-promise", release["username"]
    assert_equal "https://github.com/we-promise/sure/releases", release["source_url"]
    assert release["body_html"].present?
  end

  test "shows public feedback links" do
    get "/api/v1/app_info/feedback"

    assert_response :success
    support = response_body["support"]

    assert_includes support["feature_requests_url"], "discussions/categories/feature-requests"
    assert_includes support["bug_reports_url"], "issues/new"
    assert_includes support["community_url"], "discord.gg"
  end

  private

    def response_body
      JSON.parse(response.body)
    end
end
