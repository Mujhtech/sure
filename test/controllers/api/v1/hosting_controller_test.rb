# frozen_string_literal: true

require "test_helper"

class Api::V1::HostingControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    AutoSyncScheduler.stubs(:sync!)

    @admin = users(:family_admin)
    @admin.api_keys.active.destroy_all
    @admin_key = api_key_for(@admin, name: "Hosting Admin Key", scopes: [ "read_write" ])
    @read_key = api_key_for(@admin, name: "Hosting Read Key", scopes: [ "read" ])

    @member = users(:family_member)
    @member.api_keys.active.destroy_all
    @member_key = api_key_for(@member, name: "Hosting Member Key", scopes: [ "read_write" ])
  end

  teardown do
    Setting.openai_access_token = nil
    Setting.openai_uri_base = nil
    Setting.openai_model = nil
    Setting.openai_json_mode = nil
    Setting.anthropic_access_token = nil
    Setting.anthropic_base_url = nil
    Setting.anthropic_model = nil
    Setting.llm_provider = "openai"
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil
    Setting.external_assistant_agent_id = nil
    Setting.exchange_rate_provider = "twelve_data"
    Setting.securities_providers = ""
    Setting.onboarding_state = "open"
    Setting.syncs_include_pending = true
    Setting.auto_sync_enabled = true
    Setting.auto_sync_time = "02:22"
    Setting.llm_context_window = nil
    Setting.llm_max_response_tokens = nil
    Setting.llm_max_items_per_call = nil
  end

  test "show returns self hosting settings without leaking stored secrets" do
    Setting.openai_access_token = "openai-secret"
    Setting.external_assistant_url = "https://agent.example.com/v1/chat"
    Setting.external_assistant_token = "external-secret"
    Setting.external_assistant_agent_id = "finance-bot"

    get api_v1_hosting_url, headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal true, response_data.dig("hosting", "mode", "self_hosted")
    assert_equal true, response_data.dig("hosting", "llm", "openai", "access_token_configured")
    assert_equal true, response_data.dig("hosting", "assistant", "external", "token_configured")
    assert_equal "https://agent.example.com/v1/chat", response_data.dig("hosting", "assistant", "external", "url")
    assert_includes response_data.dig("options", "securities_providers"), "twelve_data"
    refute_includes response.body, "openai-secret"
    refute_includes response.body, "external-secret"
    refute_includes response.body, "openai_access_token"
    refute_includes response.body, "external_assistant_token"
  end

  test "show is disabled outside self hosted mode" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(false)

    get api_v1_hosting_url, headers: api_headers(@read_key)

    assert_response :forbidden
    assert_equal "feature_disabled", JSON.parse(response.body)["error"]
  end

  test "update changes admin self hosting settings and ignores redacted tokens" do
    Setting.external_assistant_token = "previous-token"

    patch api_v1_hosting_url,
          params: {
            setting: {
              openai_access_token: "new-openai-token",
              openai_uri_base: "https://api.example.com/v1",
              openai_model: "gpt-4",
              openai_json_mode: "strict",
              llm_provider: "openai",
              llm_context_window: "4096",
              llm_max_response_tokens: "1024",
              llm_max_items_per_call: "40",
              exchange_rate_provider: "yahoo_finance",
              securities_providers: %w[twelve_data tiingo],
              syncs_include_pending: false,
              auto_sync_enabled: true,
              auto_sync_time: "03:15",
              external_assistant_url: "https://agent.example.com/v1/chat",
              external_assistant_token: "********",
              external_assistant_agent_id: "finance-bot"
            },
            family: {
              assistant_type: "external"
            }
          },
          headers: api_headers(@admin_key)

    assert_response :success
    assert_equal "new-openai-token", Setting.openai_access_token
    assert_equal "https://api.example.com/v1", Setting.openai_uri_base
    assert_equal "gpt-4", Setting.openai_model
    assert_equal "strict", Setting.openai_json_mode
    assert_equal 4096, Setting.llm_context_window
    assert_equal 1024, Setting.llm_max_response_tokens
    assert_equal 40, Setting.llm_max_items_per_call
    assert_equal "yahoo_finance", Setting.exchange_rate_provider
    assert_equal %w[twelve_data tiingo], Setting.enabled_securities_providers
    assert_equal false, Setting.syncs_include_pending
    assert_equal true, Setting.auto_sync_enabled
    assert_equal "03:15", Setting.auto_sync_time
    assert_equal "previous-token", Setting.external_assistant_token
    assert_equal "external", @admin.family.reload.assistant_type
  end

  test "update requires admin" do
    patch api_v1_hosting_url,
          params: { setting: { openai_model: "gpt-4" } },
          headers: api_headers(@member_key)

    assert_response :forbidden
    assert_equal "forbidden", JSON.parse(response.body)["error"]
  end

  test "onboarding settings require super admin" do
    patch api_v1_hosting_url,
          params: { setting: { onboarding_state: "invite_only" } },
          headers: api_headers(@admin_key)

    assert_response :forbidden
    assert_equal "forbidden", JSON.parse(response.body)["error"]
  end

  test "super admin can update onboarding state" do
    super_admin = users(:sure_support_staff)
    super_admin.api_keys.active.destroy_all
    key = api_key_for(super_admin, name: "Hosting Super Admin Key", scopes: [ "read_write" ])

    patch api_v1_hosting_url,
          params: { setting: { onboarding_state: "invite_only" } },
          headers: api_headers(key)

    assert_response :success
    assert_equal "invite_only", Setting.onboarding_state
  ensure
    Setting.onboarding_state = "open"
  end

  test "update rejects invalid auto sync time" do
    patch api_v1_hosting_url,
          params: { setting: { auto_sync_time: "99:99" } },
          headers: api_headers(@admin_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "clear cache queues data cache clear job" do
    assert_enqueued_with(job: DataCacheClearJob, args: [ @admin.family ]) do
      delete clear_cache_api_v1_hosting_url, headers: api_headers(@admin_key)
    end

    assert_response :success
    assert_equal "Data cache clear queued", JSON.parse(response.body)["message"]
  end

  test "disconnect external assistant clears settings and resets assistant type" do
    Setting.external_assistant_url = "https://agent.example.com/v1/chat"
    Setting.external_assistant_token = "token"
    Setting.external_assistant_agent_id = "finance-bot"
    @admin.family.update!(assistant_type: "external")

    delete disconnect_external_assistant_api_v1_hosting_url, headers: api_headers(@admin_key)

    assert_response :success
    assert_nil Setting.external_assistant_url
    assert_nil Setting.external_assistant_token
    assert_nil Setting.external_assistant_agent_id
    assert_equal "builtin", @admin.family.reload.assistant_type
  end

  private
    def api_key_for(user, name:, scopes:)
      ApiKey.create!(
        user: user,
        name: name,
        scopes: scopes,
        source: "mobile",
        display_key: "hosting_#{SecureRandom.hex(8)}"
      )
    end
end
