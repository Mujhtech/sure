# frozen_string_literal: true

require "test_helper"
require "openssl"

class Api::V1::ProviderConnectionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @member = users(:family_member)
    @family = @user.family
    @mercury_item = mercury_items(:one)

    @user.api_keys.active.destroy_all
    @member.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_read_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @read_write_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    @member_read_write_key = ApiKey.create!(
      user: @member,
      name: "Test Member Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_member_rw_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    redis = Redis.new
    redis.del("api_rate_limit:#{@api_key.id}")
    redis.del("api_rate_limit:#{@read_write_key.id}")
    redis.del("api_rate_limit:#{@member_read_write_key.id}")
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "lists provider connection status for current family" do
    failed_sync = @mercury_item.syncs.create!(
      status: "failed",
      failed_at: Time.current,
      error: "secret token failed"
    )

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    mercury_connection = json_response["data"].detect do |connection|
      connection["id"] == @mercury_item.id && connection["provider"] == "mercury"
    end

    assert_not_nil mercury_connection
    assert_equal "mercury", mercury_connection["provider"]
    assert_equal "MercuryItem", mercury_connection["provider_type"]
    assert_equal @mercury_item.name, mercury_connection["name"]
    assert_equal @mercury_item.status, mercury_connection["status"]
    assert_includes [ true, false ], mercury_connection["requires_update"]
    assert_equal true, mercury_connection["credentials_configured"]
    assert_includes [ true, false ], mercury_connection["scheduled_for_deletion"]
    assert_includes [ true, false ], mercury_connection["pending_account_setup"]
    assert_equal @mercury_item.mercury_accounts.count, mercury_connection["accounts"]["total_count"]
    assert_equal failed_sync.id, mercury_connection["sync"]["latest"]["id"]
    assert_equal true, mercury_connection["sync"]["latest"]["error"]["present"]
    assert_equal "Sync failed", mercury_connection["sync"]["latest"]["error"]["message"]
  end

  test "reports failed sync errors as present without exposing raw messages" do
    failed_sync = @mercury_item.syncs.create!(
      status: "failed",
      failed_at: Time.current,
      error: nil
    )

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    mercury_connection = JSON.parse(response.body)["data"].detect do |connection|
      connection["id"] == @mercury_item.id && connection["provider"] == "mercury"
    end

    assert_equal failed_sync.id, mercury_connection["sync"]["latest"]["id"]
    assert_equal true, mercury_connection["sync"]["latest"]["error"]["present"]
    assert_equal "Sync failed", mercury_connection["sync"]["latest"]["error"]["message"]
  end

  test "reports stale sync errors as present" do
    stale_sync = @mercury_item.syncs.create!(
      status: "stale",
      syncing_at: 2.days.ago
    )

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    mercury_connection = JSON.parse(response.body)["data"].detect do |connection|
      connection["id"] == @mercury_item.id && connection["provider"] == "mercury"
    end

    assert_equal stale_sync.id, mercury_connection["sync"]["latest"]["id"]
    assert_equal true, mercury_connection["sync"]["latest"]["error"]["present"]
    assert_equal "Sync became stale before completion", mercury_connection["sync"]["latest"]["error"]["message"]
  end

  test "does not expose provider secrets or raw sync errors" do
    @mercury_item.syncs.create!(
      status: "failed",
      failed_at: Time.current,
      error: "raw provider token secret"
    )
    kraken_item = kraken_items(:one)
    kraken_item.syncs.create!(
      status: "failed",
      failed_at: Time.current,
      error: "raw kraken key secret"
    )

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    kraken_connection = json_response["data"].detect do |connection|
      connection["id"] == kraken_item.id && connection["provider"] == "kraken"
    end

    assert_not_nil kraken_connection
    assert_equal "KrakenItem", kraken_connection["provider_type"]
    refute_includes response.body, @mercury_item.token
    refute_includes response.body, kraken_item.api_key
    refute_includes response.body, kraken_item.api_secret
    refute_includes response.body, "raw provider token secret"
    refute_includes response.body, "raw kraken key secret"
  end

  test "fails closed when credential readiness is unknown" do
    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    plaid_connection = JSON.parse(response.body)["data"].detect do |connection|
      connection["provider"] == "plaid"
    end

    assert_not_nil plaid_connection
    assert_includes [ true, false ], plaid_connection["requires_update"]
    assert_equal false, plaid_connection["credentials_configured"]
    assert_includes [ true, false ], plaid_connection["scheduled_for_deletion"]
    assert_includes [ true, false ], plaid_connection["pending_account_setup"]
  end

  test "excludes another family's provider connections" do
    other_item = snaptrade_items(:unauthorized_item)

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    ids = JSON.parse(response.body)["data"].map { |connection| connection["id"] }
    assert_not_includes ids, other_item.id
  end

  test "read_write key can list provider connection status" do
    get api_v1_provider_connections_url, headers: api_headers(@read_write_key)
    assert_response :success
  end

  test "lists Brex provider connection status" do
    brex_item = brex_items(:one)

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    brex_connection = JSON.parse(response.body)["data"].detect do |connection|
      connection["id"] == brex_item.id && connection["provider"] == "brex"
    end

    assert_not_nil brex_connection
    assert_equal "BrexItem", brex_connection["provider_type"]
    assert_equal brex_item.name, brex_connection["name"]
    assert_equal brex_item.brex_accounts.count, brex_connection["accounts"]["total_count"]
    assert_equal brex_item.linked_accounts_count, brex_connection["accounts"]["linked_count"]
    assert_equal brex_item.unlinked_accounts_count, brex_connection["accounts"]["unlinked_count"]
  end

  test "reports credentials_configured true for an authorized SnapTrade item" do
    snaptrade_item = snaptrade_items(:configured_item)

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    snaptrade_connection = JSON.parse(response.body)["data"].detect do |connection|
      connection["id"] == snaptrade_item.id && connection["provider"] == "snaptrade"
    end

    assert_not_nil snaptrade_connection
    assert_equal true, snaptrade_connection["credentials_configured"]
  end

  test "returns an empty list when no provider connections exist" do
    ProviderConnectionStatus.stub(:for_family, []) do
      get api_v1_provider_connections_url, headers: api_headers(@api_key)
    end

    assert_response :success
    assert_equal [], JSON.parse(response.body)["data"]
  end

  test "requires authentication" do
    get api_v1_provider_connections_url
    assert_response :unauthorized
  end

  test "rejects api keys without read scope" do
    write_only_key = ApiKey.new(
      user: @user,
      name: "Test Write Key",
      scopes: [ "write" ],
      display_key: "test_write_#{SecureRandom.hex(8)}",
      source: "monitoring"
    ).tap { |api_key| api_key.save!(validate: false) }

    get api_v1_provider_connections_url, headers: api_headers(write_only_key)
    assert_response :forbidden
  end

  test "does not leak internal provider status errors" do
    ProviderConnectionStatus.stub(:for_family, ->(_family) { raise StandardError, "secret provider failure" }) do
      get api_v1_provider_connections_url, headers: api_headers(@api_key)
    end

    assert_response :internal_server_error
    assert_equal "internal_server_error", JSON.parse(response.body)["error"]
    refute_includes response.body, "secret provider failure"
  end

  test "creates credential-backed provider connection and schedules initial sync" do
    assert_difference -> { MercuryItem.where(family: @family).count }, 1 do
      assert_enqueued_jobs 1, only: SyncJob do
        post "/api/v1/provider_connections/mercury",
             params: {
               provider_connection: {
                 name: "Mobile Mercury",
                 token: "mobile-mercury-token"
               }
             },
             headers: api_headers(@read_write_key)
      end
    end

    assert_response :created

    json_response = JSON.parse(response.body)
    assert_equal "Provider connection created", json_response["message"]
    assert_equal true, json_response["sync"]["scheduled"]
    assert_equal "scheduled", json_response["sync"]["status"]
    assert_equal "mercury", json_response["provider_connection"]["provider"]
    assert_equal "Mobile Mercury", json_response["provider_connection"]["name"]
    assert_kind_of Array, json_response["data"]
    refute_includes response.body, "mobile-mercury-token"
  end

  test "creates provider connection from web-style provider params" do
    assert_difference -> { UpItem.where(family: @family).count }, 1 do
      post "/api/v1/provider_connections/up",
           params: {
             up_item: {
               name: "Mobile Up",
               access_token: "mobile-up-token"
             }
           },
           headers: api_headers(@read_write_key)
    end

    assert_response :created
    assert_equal "up", JSON.parse(response.body)["provider_connection"]["provider"]
    refute_includes response.body, "mobile-up-token"
  end

  test "creates SimpleFIN provider connection from setup token" do
    Provider::Simplefin.any_instance
      .stubs(:claim_access_url)
      .with("simplefin-setup-token")
      .returns("https://simplefin.example/access")

    assert_difference -> { SimplefinItem.where(family: @family).count }, 1 do
      assert_enqueued_jobs 1, only: SyncJob do
        post "/api/v1/provider_connections/simplefin",
             params: {
               provider_connection: {
                 name: "Mobile SimpleFIN",
                 setup_token: "simplefin-setup-token",
                 sync_start_date: "2024-01-01"
               }
             },
             headers: api_headers(@read_write_key)
      end
    end

    assert_response :created
    simplefin_item = SimplefinItem.where(family: @family).order(:created_at).last
    assert_equal "Mobile SimpleFIN", simplefin_item.name
    assert_equal "https://simplefin.example/access", simplefin_item.access_url
    assert_equal Date.new(2024, 1, 1), simplefin_item.sync_start_date

    json_response = JSON.parse(response.body)
    assert_equal "Provider connection created", json_response["message"]
    assert_equal true, json_response["sync"]["scheduled"]
    assert_equal "simplefin", json_response["provider_connection"]["provider"]
    assert_equal simplefin_item.id, json_response["provider_connection"]["id"]
    refute_includes response.body, "simplefin-setup-token"
    refute_includes response.body, "https://simplefin.example/access"
  end

  test "creates CoinStats provider connection after validating API key" do
    Provider::Coinstats.any_instance
      .expects(:get_blockchains)
      .returns(coinstats_success_response([ { name: "Ethereum", connectionId: "ethereum" } ]))

    assert_difference -> { CoinstatsItem.where(family: @family).count }, 1 do
      post "/api/v1/provider_connections/coinstats",
           params: {
             provider_connection: {
               name: "Mobile CoinStats",
               api_key: "mobile-coinstats-key",
               sync_start_date: "2024-01-01"
             }
           },
           headers: api_headers(@read_write_key)
    end

    assert_response :created
    coinstats_item = CoinstatsItem.where(family: @family).order(:created_at).last
    json_response = JSON.parse(response.body)

    assert_equal "Mobile CoinStats", coinstats_item.name
    assert_equal Date.new(2024, 1, 1), coinstats_item.sync_start_date
    assert_equal "coinstats", json_response["provider_connection"]["provider"]
    assert_equal coinstats_item.id, json_response["provider_connection"]["id"]
    assert_equal false, json_response["sync"]["scheduled"]
    refute_includes response.body, "mobile-coinstats-key"
  end

  test "updates CoinStats provider connection without exposing API key" do
    coinstats_item = create_coinstats_item
    Provider::Coinstats.any_instance
      .expects(:get_blockchains)
      .returns(coinstats_success_response([ { name: "Bitcoin", connectionId: "bitcoin" } ]))

    patch "/api/v1/provider_connections/coinstats/#{coinstats_item.id}",
          params: {
            provider_connection: {
              name: "Updated CoinStats",
              api_key: "updated-coinstats-key",
              sync_start_date: "2024-02-01"
            }
          },
          headers: api_headers(@read_write_key)

    assert_response :success
    coinstats_item.reload
    json_response = JSON.parse(response.body)

    assert_equal "Updated CoinStats", coinstats_item.name
    assert_equal Date.new(2024, 2, 1), coinstats_item.sync_start_date
    assert_equal "coinstats", json_response["provider_connection"]["provider"]
    refute_includes response.body, "updated-coinstats-key"
  end

  test "creates Enable Banking provider connection from credentials" do
    certificate = enable_banking_certificate

    assert_difference -> { EnableBankingItem.where(family: @family).count }, 1 do
      post "/api/v1/provider_connections/enable_banking",
           params: {
             provider_connection: {
               name: "Mobile Enable Banking",
               country_code: "DE",
               application_id: "enable-app-id",
               client_certificate: certificate
             }
           },
           headers: api_headers(@read_write_key)
    end

    assert_response :created
    item = EnableBankingItem.where(family: @family).order(:created_at).last
    json_response = JSON.parse(response.body)

    assert_equal "Mobile Enable Banking", item.name
    assert_equal "DE", item.country_code
    assert_equal "enable-app-id", item.application_id
    assert_equal "enable_banking", json_response["provider_connection"]["provider"]
    assert_equal false, json_response["sync"]["scheduled"]
    refute_includes response.body, certificate
  end

  test "create returns validation errors without exposing credentials" do
    assert_no_difference -> { MercuryItem.where(family: @family).count } do
      post "/api/v1/provider_connections/mercury",
           params: {
             provider_connection: {
               name: "Missing Token"
             }
           },
           headers: api_headers(@read_write_key)
    end

    assert_response :unprocessable_entity

    json_response = JSON.parse(response.body)
    assert_equal "validation_failed", json_response["error"]
    assert_equal "Provider connection could not be saved", json_response["message"]
  end

  test "create returns not found for unsupported provider setup" do
    post "/api/v1/provider_connections/not_a_provider",
         params: {
           provider_connection: {
             token: "unsupported-token"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :not_found
    assert_equal "provider_not_supported", JSON.parse(response.body)["error"]
  end

  test "create requires write scope" do
    post "/api/v1/provider_connections/mercury",
         params: {
           provider_connection: {
             name: "Read Only Mercury",
             token: "read-only-token"
           }
         },
         headers: api_headers(@api_key)

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "create requires family admin" do
    post "/api/v1/provider_connections/mercury",
         params: {
           provider_connection: {
             name: "Member Mercury",
             token: "member-token"
           }
         },
         headers: api_headers(@member_read_write_key)

    assert_response :forbidden
    assert_equal "Provider connections require a family admin", JSON.parse(response.body)["message"]
  end

  test "create does not leak internal provider errors or submitted credentials" do
    MercuryItem.any_instance.stubs(:sync_later).raises(StandardError, "secret create token failure")

    post "/api/v1/provider_connections/mercury",
         params: {
           provider_connection: {
             name: "Exploding Mercury",
             token: "submitted-secret-token"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :internal_server_error
    assert_equal "internal_server_error", JSON.parse(response.body)["error"]
    refute_includes response.body, "secret create token failure"
    refute_includes response.body, "submitted-secret-token"
  end

  test "updates provider connection and preserves blank credential fields" do
    original_token = @mercury_item.token

    patch "/api/v1/provider_connections/mercury/#{@mercury_item.id}",
          params: {
            provider_connection: {
              name: "Updated Mobile Mercury",
              token: ""
            }
          },
          headers: api_headers(@read_write_key)

    assert_response :success
    @mercury_item.reload
    assert_equal "Updated Mobile Mercury", @mercury_item.name
    assert_equal original_token, @mercury_item.token

    json_response = JSON.parse(response.body)
    assert_equal "Provider connection updated", json_response["message"]
    assert_equal false, json_response["sync"]["scheduled"]
    assert_equal "not_scheduled", json_response["sync"]["status"]
    assert_equal @mercury_item.id, json_response["provider_connection"]["id"]
    refute_includes response.body, original_token.to_s
  end

  test "updates SimpleFIN connection metadata and schedules setup token reconnect" do
    simplefin_item = @family.simplefin_items.create!(
      name: "Old SimpleFIN",
      access_url: "https://simplefin.example/old"
    )

    assert_enqueued_jobs 1, only: SimplefinConnectionUpdateJob do
      patch "/api/v1/provider_connections/simplefin/#{simplefin_item.id}",
            params: {
              provider_connection: {
                name: "Updated SimpleFIN",
                setup_token: "new-simplefin-token",
                sync_start_date: "2024-02-01"
              }
            },
            headers: api_headers(@read_write_key)
    end

    assert_response :accepted
    simplefin_item.reload
    assert_equal "Updated SimpleFIN", simplefin_item.name
    assert_equal Date.new(2024, 2, 1), simplefin_item.sync_start_date

    json_response = JSON.parse(response.body)
    assert_equal "Provider connection update scheduled", json_response["message"]
    assert_equal true, json_response["sync"]["scheduled"]
    assert_equal "simplefin", json_response["provider_connection"]["provider"]
    assert_equal simplefin_item.id, json_response["provider_connection"]["id"]
    refute_includes response.body, "new-simplefin-token"
  end

  test "dismisses SimpleFIN replacement suggestion on latest sync" do
    simplefin_item = @family.simplefin_items.create!(
      name: "Replacement SimpleFIN",
      access_url: "https://simplefin.example/access"
    )
    dormant_account = create_simplefin_provider_account(simplefin_item, name: "Old Card")
    active_account = create_simplefin_provider_account(simplefin_item, name: "New Card")
    sync = simplefin_item.syncs.create!(
      status: "completed",
      sync_stats: {
        "replacement_suggestions" => [
          {
            "dormant_sfa_id" => dormant_account.id,
            "active_sfa_id" => active_account.id
          }
        ]
      }
    )

    post "/api/v1/provider_connections/simplefin/#{simplefin_item.id}/replacement_suggestions/dismiss",
         params: {
           replacement_suggestion: {
             dormant_sfa_id: dormant_account.id,
             active_sfa_id: active_account.id
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :success

    dismissal_key = "#{dormant_account.id}:#{active_account.id}"
    json_response = JSON.parse(response.body)
    assert_equal "Replacement suggestion dismissed", json_response["message"]
    assert_equal dismissal_key, json_response.dig("replacement_suggestion", "dismissal_key")
    assert_equal true, json_response.dig("replacement_suggestion", "persisted")
    assert_includes json_response["dismissed_replacement_suggestions"], dismissal_key
    assert_includes sync.reload.sync_stats["dismissed_replacement_suggestions"], dismissal_key
  end

  test "dismiss replacement suggestion rejects non SimpleFIN provider" do
    post "/api/v1/provider_connections/mercury/#{@mercury_item.id}/replacement_suggestions/dismiss",
         params: {
           replacement_suggestion: {
             dormant_sfa_id: SecureRandom.uuid,
             active_sfa_id: SecureRandom.uuid
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :not_found
    assert_equal "provider_not_supported", JSON.parse(response.body)["error"]
  end

  test "dismiss replacement suggestion requires accounts from the SimpleFIN connection" do
    simplefin_item = @family.simplefin_items.create!(
      name: "Replacement SimpleFIN",
      access_url: "https://simplefin.example/access"
    )
    other_simplefin_item = @family.simplefin_items.create!(
      name: "Other SimpleFIN",
      access_url: "https://simplefin.example/other"
    )
    dormant_account = create_simplefin_provider_account(simplefin_item, name: "Old Card")
    active_account = create_simplefin_provider_account(other_simplefin_item, name: "Other Card")

    post "/api/v1/provider_connections/simplefin/#{simplefin_item.id}/replacement_suggestions/dismiss",
         params: {
           replacement_suggestion: {
             dormant_sfa_id: dormant_account.id,
             active_sfa_id: active_account.id
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :unprocessable_entity
    assert_equal "dormant_sfa_id and active_sfa_id must belong to this SimpleFIN connection", JSON.parse(response.body)["message"]
  end

  test "update returns not found for unsupported provider setup" do
    patch "/api/v1/provider_connections/not_a_provider/#{@mercury_item.id}",
          params: {
            provider_connection: {
              name: "Unsupported"
            }
          },
          headers: api_headers(@read_write_key)

    assert_response :not_found
    assert_equal "provider_not_supported", JSON.parse(response.body)["error"]
  end

  test "update returns not found for missing provider connection" do
    patch "/api/v1/provider_connections/mercury/#{SecureRandom.uuid}",
          params: {
            provider_connection: {
              name: "Missing"
            }
          },
          headers: api_headers(@read_write_key)

    assert_response :not_found
    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "creates a Plaid link token for mobile" do
    Family.any_instance.stubs(:get_link_token).returns("link-sandbox-token")

    post "/api/v1/provider_connections/plaid/link_token",
         params: {
           provider_connection: {
             region: "us",
             accountable_type: "Depository",
             redirect_url: "https://mobile.example/plaid/callback"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :created

    json_response = JSON.parse(response.body)
    assert_equal "plaid", json_response["provider"]
    assert_equal "create", json_response["mode"]
    assert_equal "us", json_response["region"]
    assert_equal "link-sandbox-token", json_response["link_token"]
  end

  test "Plaid link token returns provider not configured" do
    Family.any_instance.stubs(:get_link_token).returns(nil)

    post "/api/v1/provider_connections/plaid/link_token",
         params: {
           provider_connection: {
             region: "eu"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :unprocessable_entity
    assert_equal "provider_not_configured", JSON.parse(response.body)["error"]
  end

  test "creates Plaid provider connection from public token" do
    plaid_item = create_plaid_item(name: "Mobile Plaid")
    Family.any_instance.stubs(:create_plaid_item!).returns(plaid_item)

    post "/api/v1/provider_connections/plaid",
         params: {
           provider_connection: {
             public_token: "public-sandbox-token",
             item_name: "Mobile Plaid",
             region: "us"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :created

    json_response = JSON.parse(response.body)
    assert_equal "Provider connection created", json_response["message"]
    assert_equal true, json_response["sync"]["scheduled"]
    assert_equal plaid_item.id, json_response["provider_connection"]["id"]
    assert_equal "plaid", json_response["provider_connection"]["provider"]
    refute_includes response.body, "public-sandbox-token"
  end

  test "Plaid provider connection requires public token" do
    post "/api/v1/provider_connections/plaid",
         params: {
           provider_connection: {
             item_name: "Missing Token"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "creates a Plaid update link token for mobile" do
    plaid_item = create_plaid_item(name: "Update Plaid")
    PlaidItem.any_instance.stubs(:get_update_link_token).returns("update-link-token")

    post "/api/v1/provider_connections/plaid/#{plaid_item.id}/link_token",
         params: {
           provider_connection: {
             redirect_url: "https://mobile.example/plaid/update"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "plaid", json_response["provider"]
    assert_equal "update", json_response["mode"]
    assert_equal plaid_item.id, json_response["provider_connection_id"]
    assert_equal "update-link-token", json_response["link_token"]
  end

  test "loads CoinStats wallet and exchange options" do
    coinstats_item = create_coinstats_item
    Provider::Coinstats.any_instance
      .expects(:blockchain_options)
      .returns([ [ "Ethereum", "ethereum" ] ])
    Provider::Coinstats.any_instance
      .expects(:exchange_options)
      .returns([
        {
          connection_id: "bitvavo",
          name: "Bitvavo",
          icon: "https://example.com/bitvavo.png",
          connection_fields: [ { key: "apiKey", name: "API Key" } ]
        }
      ])

    get "/api/v1/provider_connections/coinstats/#{coinstats_item.id}/options", headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal "coinstats", json_response["provider"]
    assert_equal coinstats_item.id, json_response.dig("provider_connection", "id")
    assert_equal "Ethereum", json_response.dig("blockchains", 0, "label")
    assert_equal "ethereum", json_response.dig("blockchains", 0, "value")
    assert_equal "bitvavo", json_response.dig("exchanges", 0, "connection_id")
    assert_equal "apiKey", json_response.dig("exchanges", 0, "connection_fields", 0, "key")
  end

  test "links CoinStats wallet from mobile API" do
    coinstats_item = create_coinstats_item
    balance_data = [
      { coinId: "ethereum", name: "Ethereum", symbol: "ETH", amount: 1.5, price: 2000 }
    ]
    bulk_response = [
      { blockchain: "ethereum", address: "0x123abc", connectionId: "ethereum", balances: balance_data }
    ]

    Provider::Coinstats.any_instance
      .expects(:get_wallet_balances)
      .with("ethereum:0x123abc")
      .returns(coinstats_success_response(bulk_response))
    Provider::Coinstats.any_instance
      .expects(:extract_wallet_balance)
      .with(bulk_response, "0x123abc", "ethereum")
      .returns(balance_data)

    assert_difference -> { Account.where(family: @family).count }, 1 do
      assert_difference -> { CoinstatsAccount.where(coinstats_item: coinstats_item).count }, 1 do
        assert_enqueued_jobs 1, only: SyncJob do
          post "/api/v1/provider_connections/coinstats/#{coinstats_item.id}/wallets",
               params: {
                 wallet: {
                   address: "0x123abc",
                   blockchain: "ethereum"
                 }
               },
               headers: api_headers(@read_write_key)
        end
      end
    end

    assert_response :created
    json_response = JSON.parse(response.body)

    assert_equal "CoinStats wallet linked", json_response["message"]
    assert_equal 1, json_response.dig("wallet", "created_count")
    assert_equal "coinstats", json_response.dig("provider_connection", "provider")
  end

  test "links CoinStats exchange and filters unexpected connection fields" do
    coinstats_item = create_coinstats_item
    Provider::Coinstats.any_instance.expects(:exchange_options).returns([
      {
        connection_id: "bitvavo",
        name: "Bitvavo",
        connection_fields: [
          { key: "apiKey", name: "API Key" },
          { key: "apiSecret", name: "API Secret" }
        ]
      }
    ])

    linker_result = CoinstatsItem::ExchangeLinker::Result.new(success?: true, created_count: 0, errors: [])
    CoinstatsItem::ExchangeLinker.expects(:new).with(
      coinstats_item,
      connection_id: "bitvavo",
      connection_fields: { "apiKey" => "key", "apiSecret" => "secret" },
      name: "Bitvavo"
    ).returns(stub(link: linker_result))

    post "/api/v1/provider_connections/coinstats/#{coinstats_item.id}/exchanges",
         params: {
           exchange: {
             connection_id: "bitvavo",
             name: "Bitvavo",
             connection_fields: {
               apiKey: " key ",
               apiSecret: " secret ",
               unexpected: "should_not_be_forwarded"
             }
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :created
    json_response = JSON.parse(response.body)

    assert_equal "CoinStats exchange linked", json_response["message"]
    assert_equal "bitvavo", json_response.dig("exchange", "connection_id")
    assert_equal 0, json_response.dig("exchange", "created_count")
  end

  test "lists Enable Banking banks for mobile authorization" do
    item = create_enable_banking_item
    Provider::EnableBanking.any_instance.expects(:get_aspsps).with(country: "DE").returns(
      aspsps: [
        {
          name: "ING-DiBa AG",
          country: "DE",
          bic: "INGDDEFF",
          beta: false,
          logo: "https://example.com/ing.png",
          psu_types: [ "personal" ],
          auth_methods: [ { approach: "REDIRECT" } ]
        }
      ]
    )

    get "/api/v1/provider_connections/enable_banking/#{item.id}/banks", headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal "enable_banking", json_response["provider"]
    assert_equal item.id, json_response.dig("provider_connection", "id")
    assert_equal "DE", json_response["country"]
    assert_equal "ING-DiBa AG", json_response.dig("banks", 0, "name")
    assert_equal "INGDDEFF", json_response.dig("banks", 0, "bic")
  end

  test "starts Enable Banking authorization and returns redirect URL" do
    item = create_enable_banking_item
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "VR Bank in Holstein",
          country: "DE",
          psu_types: [ "personal" ],
          auth_methods: [ { name: "redirect", approach: "REDIRECT" } ]
        }
      ]
    )
    Provider::EnableBanking.any_instance.expects(:start_authorization).returns(
      url: "https://api.enablebanking.com/auth/redirect/abc",
      authorization_id: "auth_1"
    )

    post "/api/v1/provider_connections/enable_banking/#{item.id}/authorization",
         params: {
           authorization: {
             aspsp_name: "VR Bank in Holstein",
             psu_type: "personal",
             redirect_url: "usemoney://enable-banking/callback"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :created
    json_response = JSON.parse(response.body)

    assert_equal "enable_banking", json_response["provider"]
    assert_equal item.id, json_response.dig("authorization", "state")
    assert_equal "https://api.enablebanking.com/auth/redirect/abc", json_response.dig("authorization", "redirect_url")
    assert_equal "auth_1", item.reload.authorization_id
  end

  test "completes Enable Banking authorization and schedules sync" do
    item = create_enable_banking_item
    EnableBankingItem.any_instance
      .stubs(:complete_authorization)
      .with(code: "auth-code")
      .returns(session_id: "session_1", accounts: [ { uid: "account_1" } ])

    assert_enqueued_jobs 1, only: SyncJob do
      post "/api/v1/provider_connections/enable_banking/#{item.id}/authorization/complete",
           params: {
             authorization: {
               code: "auth-code",
               state: item.id
             }
           },
           headers: api_headers(@read_write_key)
    end

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal "Enable Banking authorization completed", json_response["message"]
    assert_equal "enable_banking", json_response["provider"]
    assert_equal true, json_response.dig("authorization", "completed")
    assert_equal 1, json_response.dig("authorization", "imported_accounts_count")
    assert_equal true, json_response.dig("sync", "scheduled")
  end

  test "creates Sophtron provider connection and provisions customer" do
    Provider::Sophtron.any_instance.expects(:health_check_auth).returns(sophtron_success_response({}))
    Provider::Sophtron.any_instance.expects(:list_customers).returns(sophtron_success_response([]))
    Provider::Sophtron.any_instance.expects(:create_customer).returns(
      sophtron_success_response({ CustomerID: "customer_1", CustomerName: "Sure family" })
    )

    assert_difference -> { SophtronItem.where(family: @family).count }, 1 do
      post "/api/v1/provider_connections/sophtron",
           params: {
             provider_connection: {
               name: "Mobile Sophtron",
               user_id: "sophtron-user",
               access_key: "sophtron-access-key",
               base_url: "https://api.sophtron.test/api",
               sync_start_date: "2024-01-01"
             }
           },
           headers: api_headers(@read_write_key)
    end

    assert_response :created
    item = SophtronItem.where(family: @family).order(:created_at).last
    json_response = JSON.parse(response.body)

    assert_equal "Mobile Sophtron", item.name
    assert_equal "customer_1", item.customer_id
    assert_equal Date.new(2024, 1, 1), item.sync_start_date.to_date
    assert_equal "sophtron", json_response.dig("provider_connection", "provider")
    assert_equal false, json_response.dig("sync", "scheduled")
    refute_includes response.body, "sophtron-access-key"
  end

  test "searches Sophtron institutions for mobile connection" do
    item = create_sophtron_item
    Provider::Sophtron.any_instance
      .expects(:search_institutions)
      .with("Chase")
      .returns(
        sophtron_success_response([
          {
            InstitutionID: "inst_1",
            InstitutionName: "Chase Bank",
            Url: "https://chase.example",
            City: "New York"
          }
        ])
      )

    get "/api/v1/provider_connections/sophtron/#{item.id}/institutions",
        params: { query: "Chase" },
        headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal "sophtron", json_response["provider"]
    assert_equal item.id, json_response.dig("provider_connection", "id")
    assert_equal "Chase", json_response["query"]
    assert_equal "inst_1", json_response.dig("institutions", 0, "id")
    assert_equal "Chase Bank", json_response.dig("institutions", 0, "name")
  end

  test "starts Sophtron institution connection without exposing bank credentials" do
    item = create_sophtron_item
    Provider::Sophtron.any_instance
      .expects(:create_user_institution)
      .with(institution_id: "inst_1", username: "bank-user", password: "bank-pass", pin: "")
      .returns(
        sophtron_success_response({
          JobID: "job_1",
          UserInstitutionID: "user_inst_1"
        })
      )

    post "/api/v1/provider_connections/sophtron/#{item.id}/institution",
         params: {
           connection: {
             institution_id: "inst_1",
             institution_name: "Chase Bank",
             bank_username: "bank-user",
             bank_password: "bank-pass"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :created
    item.reload
    json_response = JSON.parse(response.body)

    assert_equal "job_1", item.current_job_id
    assert_equal "user_inst_1", item.user_institution_id
    assert_equal "pending", json_response.dig("connection", "status")
    assert_equal 4, json_response.dig("connection", "next_poll_after_seconds")
    refute_includes response.body, "bank-pass"
  end

  test "polls Sophtron connection status and returns MFA challenge" do
    item = create_sophtron_item(
      institution_id: "inst_1",
      institution_name: "Chase Bank",
      user_institution_id: "user_inst_1",
      current_job_id: "job_1"
    )
    Provider::Sophtron.any_instance
      .expects(:get_job_information)
      .with("job_1")
      .returns(
        sophtron_success_response({
          LastStatus: "Challenge",
          TokenMethod: [ { name: "SMS", value: "sms" } ].to_json,
          TokenSentFlag: true,
          TokenRead: "SMS code"
        })
      )

    get "/api/v1/provider_connections/sophtron/#{item.id}/connection_status",
        headers: api_headers(@read_write_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal "mfa_required", json_response.dig("connection", "status")
    assert_equal "Challenge", json_response.dig("connection", "job_status")
    assert_equal true, json_response.dig("mfa_challenge", "token_sent")
    assert_equal "SMS", json_response.dig("mfa_challenge", "token_methods", 0, "name")
  end

  test "submits Sophtron MFA token input" do
    item = create_sophtron_item(current_job_id: "job_1", user_institution_id: "user_inst_1")
    Provider::Sophtron.any_instance
      .expects(:update_job_token_input)
      .with("job_1", token_input: "123456")
      .returns(sophtron_success_response({}))

    post "/api/v1/provider_connections/sophtron/#{item.id}/mfa",
         params: {
           mfa: {
             mfa_type: "token_input",
             token_input: "123456"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal "Sophtron MFA submitted", json_response["message"]
    assert_equal "sophtron", json_response["provider"]
    assert_equal "mfa_submitted", json_response.dig("connection", "status")
    assert_equal 4, json_response.dig("connection", "next_poll_after_seconds")
  end

  test "enables Sophtron manual sync globally" do
    item = create_sophtron_item(manual_sync: false)
    sophtron_account = create_sophtron_provider_account(item)
    AccountProvider.create!(account: create_manual_depository_account, provider: sophtron_account)

    patch "/api/v1/provider_connections/sophtron/#{item.id}/manual_sync",
          params: {
            manual_sync: {
              enabled: true
            }
          },
          headers: api_headers(@read_write_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal "Sophtron manual sync enabled", json_response["message"]
    assert_equal "sophtron", json_response["provider"]
    assert_equal true, json_response.dig("manual_sync", "enabled")
    assert_equal true, json_response.dig("manual_sync", "provider_level_enabled")
    assert_equal false, json_response.dig("manual_sync", "scoped")
    assert_equal true, item.reload.manual_sync?
  end

  test "disables Sophtron manual sync for one institution while preserving other manual accounts" do
    item = create_sophtron_item(manual_sync: true)
    target_account = create_sophtron_provider_account(item, name: "Target Checking", institution_key: "user_inst_target")
    other_account = create_sophtron_provider_account(item, name: "Other Checking", institution_key: "user_inst_other")
    AccountProvider.create!(account: create_manual_depository_account, provider: target_account)
    AccountProvider.create!(account: create_manual_credit_card_account, provider: other_account)

    patch "/api/v1/provider_connections/sophtron/#{item.id}/manual_sync",
          params: {
            manual_sync: {
              enabled: false,
              user_institution_id: "user_inst_target"
            }
          },
          headers: api_headers(@read_write_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal "Sophtron manual sync disabled", json_response["message"]
    assert_equal false, item.reload.manual_sync?
    assert_equal false, target_account.reload.manual_sync?
    assert_equal true, other_account.reload.manual_sync?
    assert_equal true, json_response.dig("manual_sync", "scoped")
    assert_equal [ target_account.id ], json_response.dig("manual_sync", "affected_account_ids")
    assert_includes json_response.dig("manual_sync", "manual_account_ids"), other_account.id
    assert_not_includes json_response.dig("manual_sync", "manual_account_ids"), target_account.id
  end

  test "rejects Sophtron manual sync toggle for unknown institution" do
    item = create_sophtron_item

    patch "/api/v1/provider_connections/sophtron/#{item.id}/manual_sync",
          params: {
            manual_sync: {
              enabled: true,
              user_institution_id: "missing_inst"
            }
          },
          headers: api_headers(@read_write_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "validation_failed", json_response["error"]
    assert_equal "No linked Sophtron accounts found for this institution", json_response["message"]
  end

  test "starts SnapTrade OAuth device flow for mobile" do
    snaptrade_item = @family.snaptrade_items.create!(name: "Mobile SnapTrade")
    Provider::Snaptrade.stubs(:oauth_client_id_configured?).returns(true)
    SnaptradeItem.any_instance
      .expects(:start_oauth_device_flow)
      .with(scope: "read")
      .returns(
        "device_code" => "device-code",
        "user_code" => "ABCD-EFGH",
        "verification_uri" => "https://dashboard.snaptrade.com/activate",
        "verification_uri_complete" => "https://dashboard.snaptrade.com/activate?user_code=ABCD-EFGH",
        "expires_in" => 600,
        "interval" => 5
      )

    post "/api/v1/provider_connections/snaptrade/oauth_device_flow",
         params: {
           provider_connection: {
             provider_connection_id: snaptrade_item.id,
             scope: "write"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :created

    json_response = JSON.parse(response.body)
    assert_equal "snaptrade", json_response["provider"]
    assert_equal snaptrade_item.id, json_response.dig("provider_connection", "id")
    assert_equal "device-code", json_response.dig("device_authorization", "device_code")
    assert_equal "ABCD-EFGH", json_response.dig("device_authorization", "user_code")
    assert_equal 5, json_response.dig("device_authorization", "interval")
  end

  test "SnapTrade OAuth device flow returns provider not configured" do
    Provider::Snaptrade.stubs(:oauth_client_id_configured?).returns(false)

    post "/api/v1/provider_connections/snaptrade/oauth_device_flow",
         headers: api_headers(@read_write_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "provider_not_configured", json_response["error"]
    assert_equal "SnapTrade OAuth client ID is not configured", json_response["message"]
  end

  test "completes SnapTrade OAuth device flow and schedules setup sync" do
    snaptrade_item = @family.snaptrade_items.create!(
      name: "Mobile SnapTrade",
      client_id: "snaptrade-client",
      consumer_key: "snaptrade-consumer",
      snaptrade_user_id: "snaptrade-user",
      snaptrade_user_secret: "snaptrade-secret"
    )
    SnaptradeItem.any_instance
      .stubs(:complete_oauth_device_flow!)
      .returns(
        "token_type" => "Bearer",
        "scope" => "read",
        "expires_in" => 3600
      )

    assert_enqueued_jobs 1, only: SyncJob do
      post "/api/v1/provider_connections/snaptrade/#{snaptrade_item.id}/oauth_device_flow/complete",
           params: {
             provider_connection: {
               device_code: "device-code"
             }
           },
           headers: api_headers(@read_write_key)
    end

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "snaptrade", json_response["provider"]
    assert_equal "Bearer", json_response.dig("oauth", "token_type")
    assert_equal "read", json_response.dig("oauth", "scope")
    assert_equal 3600, json_response.dig("oauth", "expires_in")
    assert_equal true, json_response.dig("account_setup", "ready")
    assert_equal true, json_response.dig("account_setup", "sync_scheduled")
    assert_equal false, json_response.dig("account_setup", "requires_api_credentials")
  end

  test "complete SnapTrade OAuth device flow preserves provider oauth errors" do
    snaptrade_item = @family.snaptrade_items.create!(name: "Mobile SnapTrade")
    error = Provider::Snaptrade::ApiError.new(
      "SnapTrade OAuth error (poll_device_token): authorization_pending",
      status_code: 400,
      response_body: {
        error: "authorization_pending",
        error_description: "The user has not completed authorization",
        error_uri: "https://api.snaptrade.com/docs/oauth",
        interval: 5
      }.to_json
    )
    SnaptradeItem.any_instance
      .stubs(:complete_oauth_device_flow!)
      .raises(error)

    post "/api/v1/provider_connections/snaptrade/#{snaptrade_item.id}/oauth_device_flow/complete",
         params: { provider_connection: { device_code: "device-code" } },
         headers: api_headers(@read_write_key)

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "authorization_pending", json_response["error"]
    assert_equal "The user has not completed authorization", json_response["error_description"]
    assert_equal "https://api.snaptrade.com/docs/oauth", json_response["error_uri"]
    assert_equal 5, json_response["interval"]
  end

  test "Plaid link token requires write scope" do
    post "/api/v1/provider_connections/plaid/link_token",
         params: {
           provider_connection: {
             region: "us"
           }
         },
         headers: api_headers(@api_key)

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "lists provider accounts for a provider connection" do
    provider_account = create_mercury_provider_account

    get "/api/v1/provider_connections/mercury/#{@mercury_item.id}/accounts", headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    listed_account = json_response["data"].detect { |account| account["id"] == provider_account.id }

    assert_not_nil listed_account
    assert_equal "mercury", listed_account["provider"]
    assert_equal "MercuryAccount", listed_account["provider_type"]
    assert_equal @mercury_item.id, listed_account["provider_connection_id"]
    assert_equal provider_account.name, listed_account["name"]
    assert_equal "123.45", listed_account["current_balance"]
    assert_equal [ "Depository" ], listed_account["supported_account_types"]
    assert_equal "Depository", listed_account["suggested_accountable_type"]
    assert_equal "checking", listed_account["suggested_subtype"]
    assert_equal false, listed_account["linked"]
    assert_nil listed_account["linked_account"]
    assert_equal false, json_response["meta"]["unlinked_only"]
  end

  test "lists web-supported SimpleFIN account setup types" do
    simplefin_item = @family.simplefin_items.create!(
      name: "Mobile SimpleFIN",
      access_url: "https://simplefin.example/access"
    )
    provider_account = create_simplefin_provider_account(simplefin_item)

    get "/api/v1/provider_connections/simplefin/#{simplefin_item.id}/accounts", headers: api_headers(@api_key)
    assert_response :success

    listed_account = JSON.parse(response.body)["data"].detect { |account| account["id"] == provider_account.id }

    assert_not_nil listed_account
    assert_equal "simplefin", listed_account["provider"]
    assert_includes listed_account["supported_account_types"], "Crypto"
    assert_includes listed_account["supported_account_types"], "OtherAsset"
  end

  test "lists only unlinked provider accounts when requested" do
    linked_provider_account = create_mercury_provider_account(name: "Linked Mercury")
    unlinked_provider_account = create_mercury_provider_account(name: "Unlinked Mercury")
    manual_account = create_manual_depository_account
    AccountProvider.create!(account: manual_account, provider: linked_provider_account)

    get "/api/v1/provider_connections/mercury/#{@mercury_item.id}/accounts",
        params: { unlinked_only: true },
        headers: api_headers(@api_key)
    assert_response :success

    ids = JSON.parse(response.body)["data"].map { |account| account["id"] }
    refute_includes ids, linked_provider_account.id
    assert_includes ids, unlinked_provider_account.id
  end

  test "provider account listing requires family admin" do
    get "/api/v1/provider_connections/mercury/#{@mercury_item.id}/accounts", headers: api_headers(@member_read_write_key)

    assert_response :forbidden
    assert_equal "Provider connections require a family admin", JSON.parse(response.body)["message"]
  end

  test "links a provider account to an existing manual account" do
    Sync.where(syncable_type: "MercuryItem", syncable_id: @mercury_item.id).delete_all
    provider_account = create_mercury_provider_account
    manual_account = create_manual_depository_account

    assert_no_difference -> { Account.where(family: @family).count } do
      assert_difference -> { provider_link_count(provider_account) }, 1 do
        assert_enqueued_jobs 1, only: SyncJob do
          post "/api/v1/provider_connections/mercury/#{@mercury_item.id}/accounts/#{provider_account.id}/link",
               params: {
                 provider_account: {
                   account_id: manual_account.id
                 }
               },
               headers: api_headers(@read_write_key)
        end
      end
    end

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "Provider account linked", json_response["message"]
    assert_equal manual_account.id, json_response["account"]["id"]
    assert_equal true, json_response["provider_account"]["linked"]
    assert_equal manual_account.id, json_response["provider_account"]["linked_account"]["id"]
    assert_equal true, json_response["sync"]["scheduled"]
  end

  test "creates a local account from a provider account and links it" do
    Sync.where(syncable_type: "MercuryItem", syncable_id: @mercury_item.id).delete_all
    provider_account = create_mercury_provider_account

    assert_difference -> { Account.where(family: @family, accountable_type: "Depository").count }, 1 do
      assert_difference -> { provider_link_count(provider_account) }, 1 do
        assert_enqueued_jobs 1, only: SyncJob do
          post "/api/v1/provider_connections/mercury/#{@mercury_item.id}/accounts/#{provider_account.id}/link",
               params: {
                 provider_account: {
                   accountable_type: "Depository",
                   subtype: "checking"
                 }
               },
               headers: api_headers(@read_write_key)
        end
      end
    end

    assert_response :created

    json_response = JSON.parse(response.body)
    created_account = Account.find(json_response["account"]["id"])

    assert_equal "Provider account linked to a new account", json_response["message"]
    assert_equal provider_account.name, created_account.name
    assert_equal "Depository", created_account.accountable_type
    assert_equal "checking", created_account.subtype
    assert_equal BigDecimal("123.45"), created_account.balance
    assert_equal created_account.id, provider_account.reload.account_provider.account_id
    assert_equal true, json_response["sync"]["scheduled"]
  end

  test "creates a crypto account from a SimpleFIN provider account and links it" do
    simplefin_item = @family.simplefin_items.create!(
      name: "Mobile SimpleFIN",
      access_url: "https://simplefin.example/access"
    )
    provider_account = create_simplefin_provider_account(simplefin_item, name: "SimpleFIN Wallet")

    assert_difference -> { Account.where(family: @family, accountable_type: "Crypto").count }, 1 do
      assert_difference -> { provider_link_count(provider_account) }, 1 do
        assert_enqueued_jobs 1, only: SyncJob do
          post "/api/v1/provider_connections/simplefin/#{simplefin_item.id}/accounts/#{provider_account.id}/link",
               params: {
                 provider_account: {
                   accountable_type: "Crypto"
                 }
               },
               headers: api_headers(@read_write_key)
        end
      end
    end

    assert_response :created

    json_response = JSON.parse(response.body)
    created_account = Account.find(json_response["account"]["id"])

    assert_equal "Provider account linked to a new account", json_response["message"]
    assert_equal "Crypto", created_account.accountable_type
    assert_equal "exchange", created_account.subtype
    assert_equal created_account.id, provider_account.reload.account_provider.account_id
    assert_equal true, json_response["provider_account"]["linked"]
  end

  test "rejects linking a provider account that is already linked" do
    provider_account = create_mercury_provider_account
    manual_account = create_manual_depository_account
    AccountProvider.create!(account: manual_account, provider: provider_account)

    post "/api/v1/provider_connections/mercury/#{@mercury_item.id}/accounts/#{provider_account.id}/link",
         params: {
           provider_account: {
             accountable_type: "Depository"
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :conflict
    assert_equal "provider_account_conflict", JSON.parse(response.body)["error"]
  end

  test "rejects linking an incompatible existing account type" do
    provider_account = create_mercury_provider_account
    credit_card = create_manual_credit_card_account

    post "/api/v1/provider_connections/mercury/#{@mercury_item.id}/accounts/#{provider_account.id}/link",
         params: {
           provider_account: {
             account_id: credit_card.id
           }
         },
         headers: api_headers(@read_write_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "provider account linking requires write scope" do
    provider_account = create_mercury_provider_account

    post "/api/v1/provider_connections/mercury/#{@mercury_item.id}/accounts/#{provider_account.id}/link",
         params: {
           provider_account: {
             accountable_type: "Depository"
           }
         },
         headers: api_headers(@api_key)

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "sync_all enqueues provider sync job for family admin" do
    @family.update_column(:last_sync_all_attempted_at, nil)

    assert_enqueued_with(job: SyncAllProvidersJob, args: [ @family.id ]) do
      post sync_all_api_v1_provider_connections_url, headers: api_headers(@read_write_key)
    end

    assert_response :accepted

    json_response = JSON.parse(response.body)
    assert_equal "Syncing all connected providers", json_response["message"]
    assert_equal "scheduled", json_response["sync"]["status"]
    assert_equal true, json_response["sync"]["scheduled"]
    assert_nil json_response["sync"]["provider"]
    assert_kind_of Array, json_response["data"]
  end

  test "sync_all respects recent sync throttle" do
    @family.update_column(:last_sync_all_attempted_at, Time.current)

    assert_no_enqueued_jobs only: SyncAllProvidersJob do
      post sync_all_api_v1_provider_connections_url, headers: api_headers(@read_write_key)
    end

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "Sync all was requested recently", json_response["message"]
    assert_equal "throttled", json_response["sync"]["status"]
    assert_equal false, json_response["sync"]["scheduled"]
    assert_operator json_response["sync"]["retry_after_seconds"], :>, 0
    assert_operator response.headers["Retry-After"].to_i, :>, 0
    assert_kind_of Array, json_response["data"]
  end

  test "sync_all requires write scope" do
    post sync_all_api_v1_provider_connections_url, headers: api_headers(@api_key)

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "sync_all requires family admin" do
    post sync_all_api_v1_provider_connections_url, headers: api_headers(@member_read_write_key)

    assert_response :forbidden
    assert_equal "Provider connections require a family admin", JSON.parse(response.body)["message"]
  end

  test "sync schedules syncable provider items" do
    items = MercuryItem.where(family: @family).syncable.to_a
    assert_operator items.count, :>, 0
    Sync.where(syncable_type: "MercuryItem", syncable_id: items.map(&:id)).delete_all

    assert_enqueued_jobs items.count, only: SyncJob do
      post sync_provider_api_v1_provider_connections_url(provider_key: "mercury"), headers: api_headers(@read_write_key)
    end

    assert_response :accepted

    json_response = JSON.parse(response.body)
    assert_equal "Mercury sync started", json_response["message"]
    assert_equal "mercury", json_response["sync"]["provider"]
    assert_equal "scheduled", json_response["sync"]["status"]
    assert_equal true, json_response["sync"]["scheduled"]
    assert_equal items.count, json_response["sync"]["total_count"]
    assert_equal items.count, json_response["sync"]["scheduled_count"]
    assert_equal 0, json_response["sync"]["skipped_count"]
    assert_kind_of Array, json_response["data"]
  end

  test "sync reports already syncing provider items without duplicating jobs" do
    items = MercuryItem.where(family: @family).syncable.to_a
    assert_operator items.count, :>, 0
    Sync.where(syncable_type: "MercuryItem", syncable_id: items.map(&:id)).delete_all
    items.each { |item| item.syncs.create! }

    assert_no_enqueued_jobs only: SyncJob do
      post sync_provider_api_v1_provider_connections_url(provider_key: "mercury"), headers: api_headers(@read_write_key)
    end

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "Mercury connections are already syncing", json_response["message"]
    assert_equal "already_syncing", json_response["sync"]["status"]
    assert_equal false, json_response["sync"]["scheduled"]
    assert_equal items.count, json_response["sync"]["total_count"]
    assert_equal 0, json_response["sync"]["scheduled_count"]
    assert_equal items.count, json_response["sync"]["skipped_count"]
  end

  test "sync returns not found for unsupported provider" do
    post sync_provider_api_v1_provider_connections_url(provider_key: "not_a_provider"), headers: api_headers(@read_write_key)

    assert_response :not_found
    assert_equal "provider_not_found", JSON.parse(response.body)["error"]
  end

  test "sync requires write scope" do
    post sync_provider_api_v1_provider_connections_url(provider_key: "mercury"), headers: api_headers(@api_key)

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "sync requires family admin" do
    post sync_provider_api_v1_provider_connections_url(provider_key: "mercury"), headers: api_headers(@member_read_write_key)

    assert_response :forbidden
    assert_equal "Provider connections require a family admin", JSON.parse(response.body)["message"]
  end

  test "sync does not leak internal provider errors" do
    MercuryItem.any_instance.stubs(:sync_later).raises(StandardError, "secret provider token failure")

    post sync_provider_api_v1_provider_connections_url(provider_key: "mercury"), headers: api_headers(@read_write_key)

    assert_response :internal_server_error
    assert_equal "internal_server_error", JSON.parse(response.body)["error"]
    refute_includes response.body, "secret provider token failure"
  end

  test "sync_connection schedules sync for one provider connection" do
    Sync.where(syncable: @mercury_item).delete_all

    assert_enqueued_jobs 1, only: SyncJob do
      post "/api/v1/provider_connections/mercury/#{@mercury_item.id}/sync",
           headers: api_headers(@read_write_key)
    end

    assert_response :accepted

    json_response = JSON.parse(response.body)
    assert_equal "Mercury sync started", json_response["message"]
    assert_equal "mercury", json_response["sync"]["provider"]
    assert_equal @mercury_item.id, json_response["sync"]["provider_connection_id"]
    assert_equal "full", json_response["sync"]["mode"]
    assert_equal "scheduled", json_response["sync"]["status"]
    assert_equal true, json_response["sync"]["scheduled"]
    assert_equal 1, json_response["sync"]["total_count"]
    assert_equal 1, json_response["sync"]["scheduled_count"]
    assert_equal 0, json_response["sync"]["skipped_count"]
    assert_kind_of Array, json_response["data"]
  end

  test "sync_connection reports already syncing connection without duplicating jobs" do
    Sync.where(syncable: @mercury_item).delete_all
    @mercury_item.syncs.create!

    assert_no_enqueued_jobs only: SyncJob do
      post "/api/v1/provider_connections/mercury/#{@mercury_item.id}/sync",
           headers: api_headers(@read_write_key)
    end

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "Mercury connection is already syncing", json_response["message"]
    assert_equal "already_syncing", json_response["sync"]["status"]
    assert_equal false, json_response["sync"]["scheduled"]
    assert_equal 0, json_response["sync"]["scheduled_count"]
    assert_equal 1, json_response["sync"]["skipped_count"]
  end

  test "sync_connection schedules SimpleFIN balances only sync" do
    simplefin_item = @family.simplefin_items.create!(
      name: "Mobile SimpleFIN",
      access_url: "https://simplefin.example/access"
    )

    assert_difference -> { simplefin_item.syncs.count }, 1 do
      assert_enqueued_jobs 1, only: SyncJob do
        post "/api/v1/provider_connections/simplefin/#{simplefin_item.id}/sync",
             params: { provider_connection: { mode: "balances_only" } },
             headers: api_headers(@read_write_key)
      end
    end

    assert_response :accepted

    json_response = JSON.parse(response.body)
    assert_equal "Simplefin balances-only sync started", json_response["message"]
    assert_equal "simplefin", json_response["sync"]["provider"]
    assert_equal simplefin_item.id, json_response["sync"]["provider_connection_id"]
    assert_equal "balances_only", json_response["sync"]["mode"]
    assert_equal true, json_response["sync"]["scheduled"]
  end

  test "sync_connection rejects balances only mode for non SimpleFIN provider" do
    post "/api/v1/provider_connections/mercury/#{@mercury_item.id}/sync",
         params: { mode: "balances_only" },
         headers: api_headers(@read_write_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "destroy schedules provider connection deletion" do
    assert_enqueued_with job: DestroyJob do
      delete "/api/v1/provider_connections/mercury/#{@mercury_item.id}", headers: api_headers(@read_write_key)
    end

    assert_response :accepted
    assert_equal true, @mercury_item.reload.scheduled_for_deletion?

    json_response = JSON.parse(response.body)
    assert_equal "Provider connection scheduled for deletion", json_response["message"]
    assert_equal @mercury_item.id, json_response["provider_connection"]["id"]
    assert_equal "mercury", json_response["provider_connection"]["provider"]
    assert_equal "MercuryItem", json_response["provider_connection"]["provider_type"]
    assert_equal true, json_response["provider_connection"]["scheduled_for_deletion"]

    deleted_connection = json_response["data"].detect do |connection|
      connection["id"] == @mercury_item.id && connection["provider"] == "mercury"
    end
    assert_not_nil deleted_connection
    assert_equal true, deleted_connection["scheduled_for_deletion"]
  end

  test "destroy is idempotent for already scheduled provider connection" do
    @mercury_item.update!(scheduled_for_deletion: true)

    assert_no_enqueued_jobs only: DestroyJob do
      delete "/api/v1/provider_connections/mercury/#{@mercury_item.id}", headers: api_headers(@read_write_key)
    end

    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "Provider connection is already scheduled for deletion", json_response["message"]
    assert_equal true, json_response["provider_connection"]["scheduled_for_deletion"]
  end

  test "destroy returns not found for unsupported provider" do
    delete "/api/v1/provider_connections/not_a_provider/#{@mercury_item.id}", headers: api_headers(@read_write_key)

    assert_response :not_found
    assert_equal "provider_not_found", JSON.parse(response.body)["error"]
  end

  test "destroy returns not found for missing provider connection" do
    delete "/api/v1/provider_connections/mercury/#{SecureRandom.uuid}", headers: api_headers(@read_write_key)

    assert_response :not_found
    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "destroy requires write scope" do
    delete "/api/v1/provider_connections/mercury/#{@mercury_item.id}", headers: api_headers(@api_key)

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "destroy requires family admin" do
    delete "/api/v1/provider_connections/mercury/#{@mercury_item.id}", headers: api_headers(@member_read_write_key)

    assert_response :forbidden
    assert_equal "Provider connections require a family admin", JSON.parse(response.body)["message"]
  end

  test "destroy does not leak internal provider errors" do
    MercuryItem.any_instance.stubs(:unlink_all!).raises(StandardError, "secret delete token failure")

    delete "/api/v1/provider_connections/mercury/#{@mercury_item.id}", headers: api_headers(@read_write_key)

    assert_response :internal_server_error
    assert_equal "internal_server_error", JSON.parse(response.body)["error"]
    refute_includes response.body, "secret delete token failure"
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def create_mercury_provider_account(name: "Mobile Mercury Account")
      @mercury_item.mercury_accounts.create!(
        name: name,
        account_id: "mobile_#{SecureRandom.hex(8)}",
        currency: "USD",
        current_balance: BigDecimal("123.45"),
        account_status: "active",
        account_type: "checking",
        provider: "mercury",
        institution_metadata: {
          name: "Mercury",
          domain: "mercury.com",
          url: "https://mercury.com"
        }
      )
    end

    def create_simplefin_provider_account(simplefin_item, name: "Mobile SimpleFIN Account")
      simplefin_item.simplefin_accounts.create!(
        name: name,
        account_id: "simplefin_#{SecureRandom.hex(8)}",
        currency: "USD",
        current_balance: BigDecimal("123.45"),
        available_balance: BigDecimal("123.45"),
        account_type: "checking",
        raw_payload: {
          "org" => {
            "name" => "SimpleFIN Bank",
            "domain" => "simplefin.example",
            "url" => "https://simplefin.example"
          }
        }
      )
    end

    def create_coinstats_item(name: "Mobile CoinStats")
      @family.coinstats_items.create!(
        name: name,
        api_key: "coinstats_#{SecureRandom.hex(8)}"
      )
    end

    def coinstats_success_response(data)
      Provider::Response.new(success?: true, data: data, error: nil)
    end

    def create_enable_banking_item(name: "Mobile Enable Banking")
      @family.enable_banking_items.create!(
        name: name,
        country_code: "DE",
        application_id: "enable-app-id",
        client_certificate: enable_banking_certificate
      )
    end

    def enable_banking_certificate
      @enable_banking_certificate ||= OpenSSL::PKey::RSA.new(2048).to_pem
    end

    def create_sophtron_item(attributes = {})
      @family.sophtron_items.create!(
        {
          name: "Mobile Sophtron",
          user_id: "sophtron_user_#{SecureRandom.hex(4)}",
          access_key: "sophtron_access_#{SecureRandom.hex(8)}",
          customer_id: "customer_#{SecureRandom.hex(4)}"
        }.merge(attributes)
      )
    end

    def create_sophtron_provider_account(item, name: "Mobile Sophtron Account", institution_key: "user_inst_1", manual_sync: false)
      item.sophtron_accounts.create!(
        name: name,
        account_id: "sophtron_#{SecureRandom.hex(8)}",
        currency: "USD",
        balance: BigDecimal("123.45"),
        available_balance: BigDecimal("123.45"),
        account_status: "active",
        account_type: "checking",
        account_sub_type: "checking",
        institution_metadata: {
          name: "Sophtron Bank",
          user_institution_id: institution_key
        },
        manual_sync: manual_sync
      )
    end

    def sophtron_success_response(data)
      Provider::Response.new(success?: true, data: data, error: nil)
    end

    def create_plaid_item(name:)
      @family.plaid_items.create!(
        name: name,
        plaid_id: "plaid_#{SecureRandom.hex(8)}",
        access_token: "access_#{SecureRandom.hex(8)}",
        plaid_region: "us"
      )
    end

    def create_manual_depository_account
      Account.create!(
        family: @family,
        owner: @user,
        name: "Manual Checking",
        balance: BigDecimal("25"),
        cash_balance: BigDecimal("25"),
        currency: "USD",
        accountable: Depository.new(subtype: Depository::DEFAULT_SUBTYPE)
      )
    end

    def create_manual_credit_card_account
      Account.create!(
        family: @family,
        owner: @user,
        name: "Manual Card",
        balance: BigDecimal("100"),
        cash_balance: BigDecimal("100"),
        currency: "USD",
        accountable: CreditCard.new(subtype: CreditCard::DEFAULT_SUBTYPE)
      )
    end

    def provider_link_count(provider_account)
      AccountProvider.where(
        provider_type: provider_account.class.name,
        provider_id: provider_account.id
      ).count
    end
end
