# frozen_string_literal: true

require "test_helper"

class Api::V1::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )
  end

  # -- Authentication --------------------------------------------------------

  test "reset requires authentication" do
    delete "/api/v1/users/reset"
    assert_response :unauthorized
  end

  test "reset with sample data requires authentication" do
    delete "/api/v1/users/reset_with_sample_data"
    assert_response :unauthorized
  end

  test "destroy requires authentication" do
    delete "/api/v1/users/me"
    assert_response :unauthorized
  end

  # -- Scope enforcement -----------------------------------------------------

  test "reset requires write scope" do
    delete "/api/v1/users/reset", headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "reset with sample data requires write scope" do
    delete "/api/v1/users/reset_with_sample_data", headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "destroy requires write scope" do
    delete "/api/v1/users/me", headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "show returns current user profile" do
    get "/api/v1/users/me", headers: api_headers(@read_only_api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal @user.id, body["user"]["id"]
    assert_equal @user.email, body["user"]["email"]
    assert_equal @user.family.id, body["family"]["id"]
    assert_includes body["options"]["default_periods"], "last_30_days"
    assert_includes body["options"]["default_account_orders"], "name_asc"
  end

  test "update changes current user profile preferences" do
    patch "/api/v1/users/me",
          params: {
            user: {
              first_name: "Mobile",
              last_name: "User",
              default_period: "last_7_days",
              default_account_order: "balance_desc",
              theme: "dark",
              show_sidebar: false,
              show_ai_sidebar: false,
              goals: [ "Track spending" ]
            }
          },
          headers: api_headers(@api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    @user.reload

    assert_equal "Mobile", @user.first_name
    assert_equal "User", @user.last_name
    assert_equal "last_7_days", body["user"]["default_period"]
    assert_equal "balance_desc", body["user"]["default_account_order"]
    assert_equal "dark", body["user"]["theme"]
    assert_equal false, body["user"]["show_sidebar"]
    assert_equal false, body["user"]["show_ai_sidebar"]
    assert_equal [ "Track spending" ], body["user"]["goals"]
  end

  test "read-only key cannot update current user profile" do
    patch "/api/v1/users/me",
          params: { user: { first_name: "Blocked" } },
          headers: api_headers(@read_only_api_key)

    assert_response :forbidden
    assert_not_equal "Blocked", @user.reload.first_name
  end

  test "admin can update family settings through profile" do
    patch "/api/v1/users/me",
          params: {
            user: {
              family: {
                name: "Mobile Family",
                moniker: "Household",
                default_account_sharing: "private",
                month_start_day: 5
              }
            }
          },
          headers: api_headers(@api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    family = @user.family.reload

    assert_equal "Mobile Family", family.name
    assert_equal "Household", family.moniker
    assert_equal "private", family.default_account_sharing
    assert_equal 5, family.month_start_day
    assert_equal "Mobile Family", body["family"]["name"]
  end

  test "non-admin cannot update family settings through profile" do
    member = users(:family_member)
    member.api_keys.active.destroy_all
    member_key = ApiKey.create!(
      user: member,
      name: "Member Profile Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "member_profile_#{SecureRandom.hex(8)}"
    )

    patch "/api/v1/users/me",
          params: { user: { family: { name: "Blocked Family" } } },
          headers: api_headers(member_key)

    assert_response :forbidden
    assert_not_equal "Blocked Family", member.family.reload.name
  end

  test "rule prompt settings update current user" do
    timestamp = Time.current.iso8601

    patch "/api/v1/users/me/rule_prompt_settings",
          params: {
            user: {
              rule_prompts_disabled: true,
              rule_prompt_dismissed_at: timestamp
            }
          },
          headers: api_headers(@api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    @user.reload

    assert_equal true, @user.rule_prompts_disabled?
    assert_equal true, body["user"]["rule_prompts_disabled"]
    assert_not_nil body["user"]["rule_prompt_dismissed_at"]
  end

  test "updates current user password with password challenge" do
    patch "/api/v1/users/me/password",
          params: {
            user: {
              password: "new-mobile-password-123",
              password_confirmation: "new-mobile-password-123",
              password_challenge: user_password_test
            }
          },
          headers: api_headers(@api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal @user.id, body.dig("user", "id")
    assert @user.reload.authenticate("new-mobile-password-123")
  end

  test "rejects current user password update with invalid password challenge" do
    patch "/api/v1/users/me/password",
          params: {
            user: {
              password: "new-mobile-password-123",
              password_confirmation: "new-mobile-password-123",
              password_challenge: "wrong-password"
            }
          },
          headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
    assert_equal "Password could not be updated", body["message"]
    assert_not @user.reload.authenticate("new-mobile-password-123")
  end

  test "read-only key cannot update current user password" do
    patch "/api/v1/users/me/password",
          params: {
            user: {
              password: "new-mobile-password-123",
              password_confirmation: "new-mobile-password-123",
              password_challenge: user_password_test
            }
          },
          headers: api_headers(@read_only_api_key)

    assert_response :forbidden
    assert_not @user.reload.authenticate("new-mobile-password-123")
  end

  # -- Reset -----------------------------------------------------------------


  test "reset requires admin role" do
    non_admin_api_key = ApiKey.create!(
      user: users(:family_member),
      name: "Member Read-Write Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_member_#{SecureRandom.hex(8)}"
    )

    assert_no_enqueued_jobs only: FamilyResetJob do
      delete "/api/v1/users/reset", headers: api_headers(non_admin_api_key)
    end

    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "You are not authorized to perform this action", body["message"]
  end

  test "reset with sample data requires admin role" do
    non_admin_api_key = ApiKey.create!(
      user: users(:family_member),
      name: "Member Sample Reset Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_member_sample_#{SecureRandom.hex(8)}"
    )

    assert_no_enqueued_jobs only: FamilyResetJob do
      delete "/api/v1/users/reset_with_sample_data", headers: api_headers(non_admin_api_key)
    end

    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "You are not authorized to perform this action", body["message"]
  end

  test "reset enqueues FamilyResetJob and returns 200" do
    assert_enqueued_with(job: FamilyResetJob, args: [ @user.family ]) do
      delete "/api/v1/users/reset", headers: api_headers(@api_key)
    end

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Account reset has been initiated", body["message"]
    assert_equal "queued", body["status"]
    assert_equal @user.family.id, body["family_id"]
    assert_equal false, body["sample_data"]
    assert body["job_id"].present?
    assert_equal "/api/v1/users/reset/status", body["status_url"]
  end

  test "reset with sample data enqueues FamilyResetJob with current user email and returns 200" do
    job = Struct.new(:job_id).new("sample-reset-job-id")
    FamilyResetJob
      .expects(:perform_later)
      .with(@user.family, load_sample_data_for_email: @user.email)
      .returns(job)

    delete "/api/v1/users/reset_with_sample_data", headers: api_headers(@api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Account reset with sample data has been initiated", body["message"]
    assert_equal "queued", body["status"]
    assert_equal "sample-reset-job-id", body["job_id"]
    assert_equal @user.family.id, body["family_id"]
    assert_equal true, body["sample_data"]
    assert_equal "/api/v1/users/reset/status", body["status_url"]
  end

  test "reset returns controlled error when enqueue fails" do
    FamilyResetJob.stub(:perform_later, ->(_family) { raise StandardError, "queue down" }) do
      delete "/api/v1/users/reset", headers: api_headers(@api_key)
    end

    assert_response :internal_server_error
    body = JSON.parse(response.body)
    assert_equal "reset_enqueue_failed", body["error"]
    assert_equal "Account reset could not be queued", body["message"]
    assert_not_includes response.body, "queue down"
  end

  test "reset with sample data returns controlled error when enqueue fails" do
    FamilyResetJob
      .expects(:perform_later)
      .with(@user.family, load_sample_data_for_email: @user.email)
      .raises(StandardError, "sample queue down")

    delete "/api/v1/users/reset_with_sample_data", headers: api_headers(@api_key)

    assert_response :internal_server_error
    body = JSON.parse(response.body)
    assert_equal "reset_enqueue_failed", body["error"]
    assert_equal "Account reset could not be queued", body["message"]
    assert_not_includes response.body, "sample queue down"
  end

  test "reset status requires authentication" do
    get "/api/v1/users/reset/status"
    assert_response :unauthorized
  end

  test "reset status requires admin role" do
    non_admin_api_key = ApiKey.create!(
      user: users(:family_member),
      name: "Member Read Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_member_read_#{SecureRandom.hex(8)}"
    )

    get "/api/v1/users/reset/status", headers: api_headers(non_admin_api_key)

    assert_response :forbidden
  end

  test "reset status returns family data counts" do
    import_session = @user.family.import_sessions.create!(expected_chunks: 1)
    import_session.imports.create!(
      family: @user.family,
      type: "SureImport",
      sequence: 1,
      checksum: "a" * 64
    )
    import_session.source_mappings.create!(
      family: @user.family,
      source_type: "Category",
      source_id: "source-category-1",
      target: @user.family.categories.first
    )

    get "/api/v1/users/reset/status", headers: api_headers(@read_only_api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal @user.family.id, body["family_id"]
    assert_includes %w[complete data_remaining], body["status"]
    assert_equal body["counts"].values.sum.zero?, body["reset_complete"]
    assert_equal expected_reset_count_keys.sort, body["counts"].keys.sort
    assert_equal 1, body["counts"]["import_sessions"]
    assert_equal 1, body["counts"]["import_source_mappings"]
  end

  test "reset status ignores the follow-up family sync after reset" do
    family = @user.family
    Provider::Registry.stubs(:plaid_provider_for_region).returns(nil)
    Family::FinancialDataReset.new(family: family, dry_run: false, confirmed: true).call
    family.syncs.create!

    get "/api/v1/users/reset/status", headers: api_headers(@read_only_api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "complete", body["status"]
    assert_equal true, body["reset_complete"]
    assert_not body["counts"].key?("syncs")
  end

  # -- Delete account --------------------------------------------------------

  test "destroy deactivates user and returns 200" do
    solo_family = Family.create!(name: "Solo Family", currency: "USD", locale: "en", date_format: "%m-%d-%Y")
    solo_user = solo_family.users.create!(
      email: "solo@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: :admin
    )
    solo_api_key = ApiKey.create!(
      user: solo_user,
      name: "Solo Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_solo_#{SecureRandom.hex(8)}"
    )

    delete "/api/v1/users/me", headers: api_headers(solo_api_key)
    assert_response :ok

    body = JSON.parse(response.body)
    assert_equal "Account has been deleted", body["message"]

    solo_user.reload
    assert_not solo_user.active?
    assert_not_equal "solo@example.com", solo_user.email
  end

  test "destroy returns 422 when admin has other family members" do
    delete "/api/v1/users/me", headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    body = JSON.parse(response.body)
    assert_equal "Failed to delete account", body["error"]
  end

  # -- Deactivated user ------------------------------------------------------

  test "rejects deactivated user with 401" do
    @user.update_column(:active, false)

    delete "/api/v1/users/reset", headers: api_headers(@api_key)
    assert_response :unauthorized

    body = JSON.parse(response.body)
    assert_equal "Account has been deactivated", body["message"]
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def expected_reset_count_keys
      Family::FinancialDataReset::STATUS_COUNT_KEYS.map(&:to_s)
    end
end
