# frozen_string_literal: true

require "swagger_helper"
require "openssl"

RSpec.describe "Api::V1::ProviderConnections", type: :request do
  let(:user) { users(:family_admin) }
  let(:member) { users(:family_member) }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "API Docs Key",
      key: key,
      scopes: %w[read_write],
      source: "web"
    )
  end
  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    ApiKey.new(
      user: user,
      name: "API Docs Write Key",
      key: key,
      scopes: %w[write],
      source: "web"
    ).tap { |api_key| api_key.save!(validate: false) }
  end
  let(:member_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: member,
      name: "API Docs Member Key",
      key: key,
      scopes: %w[read_write],
      source: "mobile"
    )
  end
  let(:'X-Api-Key') { api_key.plain_key }

  path "/api/v1/provider_connections" do
    get "Lists provider connection status summaries" do
      description "List safe provider connection status metadata for the authenticated user's family without exposing credentials, raw provider payloads, or raw sync errors."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "provider connection status summaries listed" do
        schema "$ref" => "#/components/schemas/ProviderConnectionCollection"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/plaid/link_token" do
    post "Creates a Plaid Link token" do
      description "Creates a Plaid Link token for mobile Plaid onboarding. The mobile client presents this token in Plaid Link and then exchanges the resulting public_token through POST /api/v1/provider_connections/plaid."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          provider_connection: {
            type: :object,
            properties: {
              region: { type: :string, enum: %w[us eu], default: "us" },
              accountable_type: { type: :string, enum: %w[Depository CreditCard Loan Investment], default: "Depository" },
              redirect_url: { type: :string, nullable: true }
            }
          }
        }
      }

      let(:body) { { provider_connection: { region: "us", accountable_type: "Depository" } } }

      response "201", "Plaid Link token created" do
        before do
          allow_any_instance_of(Family).to receive(:get_link_token).and_return("docs-plaid-link-token")
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionPlaidLinkToken"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "422", "Plaid not configured" do
        before do
          allow_any_instance_of(Family).to receive(:get_link_token).and_return(nil)
        end

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/plaid/{id}/link_token" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Plaid provider connection item ID"

    post "Creates a Plaid update Link token" do
      description "Creates a Plaid Link token in update mode for an existing Plaid connection. Use when Plaid requires an item update or credential refresh."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          provider_connection: {
            type: :object,
            properties: {
              redirect_url: { type: :string, nullable: true }
            }
          }
        }
      }

      let(:id) { plaid_items(:one).id }
      let(:body) { { provider_connection: { redirect_url: "https://mobile.example/plaid/update" } } }

      response "200", "Plaid update Link token created" do
        before do
          allow_any_instance_of(PlaidItem).to receive(:get_update_link_token).and_return("docs-plaid-update-token")
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionPlaidLinkToken"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "Plaid connection not found" do
        let(:id) { SecureRandom.uuid }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/snaptrade/oauth_device_flow" do
    post "Starts a SnapTrade OAuth device flow" do
      description "Starts SnapTrade OAuth device authorization for mobile. The response contains user_code and verification URLs for the user to authorize brokerage access."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          provider_connection: {
            type: :object,
            properties: {
              provider_connection_id: { type: :string, format: :uuid, nullable: true },
              scope: { type: :string, enum: %w[read], default: "read" },
              name: { type: :string, nullable: true }
            }
          }
        }
      }

      let(:snaptrade_item) { user.family.snaptrade_items.create!(name: "Docs SnapTrade") }
      let(:body) { { provider_connection: { provider_connection_id: snaptrade_item.id, scope: "read" } } }

      response "201", "SnapTrade OAuth device flow started" do
        before do
          allow(Provider::Snaptrade).to receive(:oauth_client_id_configured?).and_return(true)
          allow_any_instance_of(SnaptradeItem).to receive(:start_oauth_device_flow).and_return(
            "device_code" => "docs-device-code",
            "user_code" => "ABCD-EFGH",
            "verification_uri" => "https://dashboard.snaptrade.com/activate",
            "verification_uri_complete" => "https://dashboard.snaptrade.com/activate?user_code=ABCD-EFGH",
            "expires_in" => 600,
            "interval" => 5
          )
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionSnaptradeOAuthStartResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "422", "SnapTrade OAuth client ID missing" do
        before do
          allow(Provider::Snaptrade).to receive(:oauth_client_id_configured?).and_return(false)
        end

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/snaptrade/{id}/oauth_device_flow/complete" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "SnapTrade provider connection item ID"

    post "Completes a SnapTrade OAuth device flow" do
      description "Polls SnapTrade's OAuth token endpoint with the device_code after the user authorizes. When the SnapTrade item also has API credentials, the API prepares account setup and schedules a sync."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[provider_connection],
        properties: {
          provider_connection: {
            type: :object,
            required: %w[device_code],
            properties: {
              device_code: { type: :string }
            }
          }
        }
      }

      let(:snaptrade_item) do
        user.family.snaptrade_items.create!(
          name: "Docs SnapTrade",
          client_id: "docs-client",
          consumer_key: "docs-consumer",
          snaptrade_user_id: "docs-user",
          snaptrade_user_secret: "docs-secret"
        )
      end
      let(:id) { snaptrade_item.id }
      let(:body) { { provider_connection: { device_code: "docs-device-code" } } }

      response "200", "SnapTrade OAuth device flow completed" do
        before do
          allow_any_instance_of(SnaptradeItem).to receive(:complete_oauth_device_flow!).and_return(
            "token_type" => "Bearer",
            "scope" => "read",
            "expires_in" => 3600
          )
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionSnaptradeOAuthCompleteResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "SnapTrade connection not found" do
        let(:id) { SecureRandom.uuid }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "422", "device code missing" do
        let(:body) { { provider_connection: {} } }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/{provider_key}" do
    parameter name: :provider_key, in: :path, type: :string, description: "Provider key. Credential-backed setup supports akahu, up, lunchflow, mercury, brex, sophtron, coinbase, binance, kraken, ibkr, indexa_capital, coinstats, and enable_banking. Plaid supports public_token exchange. SimpleFIN supports setup_token claim."

    post "Creates a provider connection" do
      description "Creates a provider connection, schedules the initial sync when the provider supports it, and returns safe provider connection status metadata. Credential-backed providers accept their API credentials. Plaid accepts the public_token returned by Plaid Link. SimpleFIN accepts a setup_token from SimpleFIN Bridge. CoinStats validates api_key before saving. Sophtron validates credentials and provisions a family customer before institution login. Enable Banking accepts country_code, application_id, and client_certificate before bank authorization."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[provider_connection],
        properties: {
          provider_connection: {
            type: :object,
            properties: {
              name: { type: :string },
              sync_start_date: { type: :string, format: :date },
              token: { type: :string, description: "Mercury or Brex token" },
              base_url: { type: :string, nullable: true },
              api_key: { type: :string, description: "CoinStats, Coinbase, Binance, Kraken, or Lunch Flow API key" },
              api_secret: { type: :string, description: "Coinbase, Binance, or Kraken API secret" },
              access_token: { type: :string, description: "Up access token" },
              app_token: { type: :string, description: "Akahu app token" },
              user_token: { type: :string, description: "Akahu user token" },
              query_id: { type: :string, description: "Interactive Brokers Flex Query ID" },
              api_token: { type: :string, description: "Indexa Capital API token" },
              username: { type: :string, description: "Indexa Capital username" },
              document: { type: :string, description: "Indexa Capital document identifier" },
              password: { type: :string, description: "Indexa Capital password" },
              public_token: { type: :string, description: "Plaid public token returned by Plaid Link" },
              region: { type: :string, enum: %w[us eu], description: "Plaid region" },
              item_name: { type: :string, description: "Plaid, SimpleFIN, or CoinStats institution display name" },
              setup_token: { type: :string, description: "SimpleFIN setup token returned by SimpleFIN Bridge" },
              country_code: { type: :string, description: "Enable Banking ASPSP country code" },
              application_id: { type: :string, description: "Enable Banking application ID" },
              client_certificate: { type: :string, description: "Enable Banking private key PEM" },
              user_id: { type: :string, description: "Sophtron User ID" },
              access_key: { type: :string, description: "Sophtron Access Key" }
            }
          }
        }
      }

      let(:provider_key) { "mercury" }
      let(:body) do
        {
          provider_connection: {
            name: "Mobile Mercury",
            token: "mercury-docs-token"
          }
        }
      end

      response "201", "provider connection created" do
        schema "$ref" => "#/components/schemas/ProviderConnectionMutationResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "provider not supported" do
        let(:provider_key) { "not_a_provider" }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "422", "provider connection validation failed" do
        let(:body) { { provider_connection: { name: "Missing Token" } } }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/{provider_key}/{id}" do
    parameter name: :provider_key, in: :path, type: :string, description: "Credential-backed provider key. Supported here: akahu, up, lunchflow, mercury, brex, sophtron, coinbase, binance, kraken, ibkr, indexa_capital, coinstats, and enable_banking. SimpleFIN supports metadata updates and setup_token reconnect."
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Provider connection item ID from the provider connection status list"

    patch "Updates a provider connection" do
      description "Updates safe provider connection settings or credentials. Blank credential fields are ignored on update so clients can edit metadata without resubmitting secrets. SimpleFIN setup_token updates are queued because reconnect can take longer than a mobile request should wait. CoinStats validates a nonblank api_key before saving. Sophtron validates nonblank credential changes and reprovisions the family customer if needed."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[provider_connection],
        properties: {
          provider_connection: {
            type: :object,
            properties: {
              name: { type: :string },
              sync_start_date: { type: :string, format: :date },
              token: { type: :string },
              base_url: { type: :string, nullable: true },
              api_key: { type: :string },
              api_secret: { type: :string },
              access_token: { type: :string },
              app_token: { type: :string },
              user_token: { type: :string },
              query_id: { type: :string },
              api_token: { type: :string },
              username: { type: :string },
              document: { type: :string },
              password: { type: :string },
              setup_token: { type: :string, description: "SimpleFIN setup token for reconnecting an existing item" },
              country_code: { type: :string },
              application_id: { type: :string },
              client_certificate: { type: :string, description: "Enable Banking private key PEM. Blank values are ignored on update." },
              user_id: { type: :string, description: "Sophtron User ID. Blank values are ignored on update." },
              access_key: { type: :string, description: "Sophtron Access Key. Blank values are ignored on update." }
            }
          }
        }
      }

      let(:provider_key) { "mercury" }
      let(:id) { mercury_items(:one).id }
      let(:body) { { provider_connection: { name: "Updated Mercury", token: "" } } }

      response "200", "provider connection updated" do
        schema "$ref" => "#/components/schemas/ProviderConnectionMutationResponse"
        run_test!
      end

      response "202", "SimpleFIN reconnect scheduled" do
        let(:provider_key) { "simplefin" }
        let(:simplefin_item) do
          user.family.simplefin_items.create!(
            name: "Docs SimpleFIN",
            access_url: "https://simplefin.example/access"
          )
        end
        let(:id) { simplefin_item.id }
        let(:body) do
          {
            provider_connection: {
              setup_token: "simplefin-docs-token",
              sync_start_date: "2024-01-01"
            }
          }
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionMutationResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "provider connection not found" do
        let(:id) { SecureRandom.uuid }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end

    delete "Schedules a provider connection for deletion" do
      description "Detaches provider account links when supported, schedules the provider connection for deletion, and returns refreshed safe provider connection status metadata. Requires a read_write key and family admin user."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      let(:provider_key) { "mercury" }
      let(:id) { mercury_items(:one).id }

      response "202", "provider connection scheduled for deletion" do
        schema "$ref" => "#/components/schemas/ProviderConnectionDestroyActionResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "provider not found" do
        let(:provider_key) { "not_a_provider" }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "connection not found" do
        let(:id) { SecureRandom.uuid }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/coinstats/{id}/options" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "CoinStats provider connection ID"

    get "Lists CoinStats wallet and exchange link options" do
      description "Returns supported CoinStats blockchains for wallet linking and supported exchange connection definitions with required credential field keys."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      let(:coinstats_item) { user.family.coinstats_items.create!(name: "Docs CoinStats", api_key: "docs-coinstats-key") }
      let(:id) { coinstats_item.id }

      response "200", "CoinStats options loaded" do
        before do
          allow_any_instance_of(Provider::Coinstats).to receive(:blockchain_options).and_return([ [ "Ethereum", "ethereum" ] ])
          allow_any_instance_of(Provider::Coinstats).to receive(:exchange_options).and_return([
            {
              connection_id: "bitvavo",
              name: "Bitvavo",
              icon: "https://example.com/bitvavo.png",
              connection_fields: [ { key: "apiKey", name: "API Key" } ]
            }
          ])
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionCoinstatsOptionsResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "connection not found" do
        let(:id) { SecureRandom.uuid }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/coinstats/{id}/wallets" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "CoinStats provider connection ID"

    post "Links a CoinStats wallet" do
      description "Fetches CoinStats wallet balances for a blockchain/address pair and creates local crypto accounts for discovered token balances."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[wallet],
        properties: {
          wallet: {
            type: :object,
            required: %w[address blockchain],
            properties: {
              address: { type: :string },
              blockchain: { type: :string, description: "Blockchain value from the CoinStats options endpoint." }
            }
          }
        }
      }

      let(:coinstats_item) { user.family.coinstats_items.create!(name: "Docs CoinStats", api_key: "docs-coinstats-key") }
      let(:id) { coinstats_item.id }
      let(:body) { { wallet: { address: "0x123abc", blockchain: "ethereum" } } }

      response "201", "CoinStats wallet linked" do
        before do
          result = CoinstatsItem::WalletLinker::Result.new(success?: true, created_count: 1, errors: [])
          allow(CoinstatsItem::WalletLinker).to receive(:new).and_return(double(link: result))
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionCoinstatsWalletLinkResponse"
        run_test!
      end

      response "422", "wallet link validation failed" do
        let(:body) { { wallet: { address: "0x123abc" } } }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/coinstats/{id}/exchanges" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "CoinStats provider connection ID"

    post "Links a CoinStats exchange" do
      description "Connects a supported CoinStats exchange portfolio. Unknown connection_fields are ignored; required field keys come from the options endpoint."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[exchange],
        properties: {
          exchange: {
            type: :object,
            required: %w[connection_id connection_fields],
            properties: {
              connection_id: { type: :string },
              name: { type: :string },
              connection_fields: {
                type: :object,
                additionalProperties: { type: :string }
              }
            }
          }
        }
      }

      let(:coinstats_item) { user.family.coinstats_items.create!(name: "Docs CoinStats", api_key: "docs-coinstats-key") }
      let(:id) { coinstats_item.id }
      let(:body) { { exchange: { connection_id: "bitvavo", name: "Bitvavo", connection_fields: { apiKey: "key" } } } }

      response "201", "CoinStats exchange linked" do
        before do
          allow_any_instance_of(Provider::Coinstats).to receive(:exchange_options).and_return([
            {
              connection_id: "bitvavo",
              name: "Bitvavo",
              connection_fields: [ { key: "apiKey", name: "API Key" } ]
            }
          ])
          result = CoinstatsItem::ExchangeLinker::Result.new(success?: true, created_count: 0, errors: [])
          allow(CoinstatsItem::ExchangeLinker).to receive(:new).and_return(double(link: result))
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionCoinstatsExchangeLinkResponse"
        run_test!
      end

      response "422", "exchange link validation failed" do
        let(:body) { { exchange: { name: "Missing Connection" } } }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/enable_banking/{id}/banks" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Enable Banking provider connection ID"
    parameter name: :country, in: :query, type: :string, required: false, description: "Override ASPSP country code. Defaults to the connection country_code."

    get "Lists Enable Banking banks" do
      description "Returns ASPSPs available for the Enable Banking connection's country so mobile can let the user choose a bank before authorization."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      let(:enable_banking_item) do
        user.family.enable_banking_items.create!(
          name: "Docs Enable Banking",
          country_code: "DE",
          application_id: "enable-docs-app",
          client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem
        )
      end
      let(:id) { enable_banking_item.id }

      response "200", "Enable Banking banks listed" do
        before do
          allow_any_instance_of(Provider::EnableBanking).to receive(:get_aspsps).and_return(
            aspsps: [
              {
                name: "ING-DiBa AG",
                country: "DE",
                bic: "INGDDEFF",
                beta: false,
                psu_types: [ "personal" ],
                auth_methods: [ { approach: "REDIRECT" } ]
              }
            ]
          )
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionEnableBankingBanksResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/enable_banking/{id}/authorization" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Enable Banking provider connection ID"

    post "Starts Enable Banking authorization" do
      description "Starts Enable Banking authorization and returns the hosted redirect URL instead of issuing an HTTP redirect."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[authorization],
        properties: {
          authorization: {
            type: :object,
            required: %w[aspsp_name],
            properties: {
              aspsp_name: { type: :string },
              psu_type: { type: :string, default: "personal" },
              redirect_url: { type: :string, description: "Mobile deep link or universal link registered with Enable Banking." },
              language: { type: :string },
              new_connection: { type: :boolean, description: "When true, clones credentials into a new provider connection before authorization." }
            }
          }
        }
      }

      let(:enable_banking_item) do
        user.family.enable_banking_items.create!(
          name: "Docs Enable Banking",
          country_code: "DE",
          application_id: "enable-docs-app",
          client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem
        )
      end
      let(:id) { enable_banking_item.id }
      let(:body) { { authorization: { aspsp_name: "VR Bank", psu_type: "personal", redirect_url: "usemoney://enable-banking/callback" } } }

      response "201", "Enable Banking authorization started" do
        before do
          allow_any_instance_of(Provider::EnableBanking).to receive(:get_aspsps).and_return(
            aspsps: [
              {
                name: "VR Bank",
                country: "DE",
                psu_types: [ "personal" ],
                auth_methods: [ { name: "redirect", approach: "REDIRECT" } ]
              }
            ]
          )
          allow_any_instance_of(Provider::EnableBanking).to receive(:start_authorization).and_return(
            url: "https://api.enablebanking.com/auth/redirect/docs",
            authorization_id: "auth_docs"
          )
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionEnableBankingAuthorizationStartResponse"
        run_test!
      end

      response "422", "bank missing" do
        let(:body) { { authorization: {} } }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/enable_banking/{id}/authorization/complete" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Enable Banking provider connection ID"

    post "Completes Enable Banking authorization" do
      description "Exchanges the authorization code for an Enable Banking session and schedules provider sync."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[authorization],
        properties: {
          authorization: {
            type: :object,
            required: %w[code],
            properties: {
              code: { type: :string },
              state: { type: :string, format: :uuid }
            }
          }
        }
      }

      let(:enable_banking_item) do
        user.family.enable_banking_items.create!(
          name: "Docs Enable Banking",
          country_code: "DE",
          application_id: "enable-docs-app",
          client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem
        )
      end
      let(:id) { enable_banking_item.id }
      let(:body) { { authorization: { code: "auth-code", state: enable_banking_item.id } } }

      response "200", "Enable Banking authorization completed" do
        before do
          allow_any_instance_of(EnableBankingItem).to receive(:complete_authorization).and_return(
            session_id: "session_docs",
            accounts: [ { uid: "account_docs" } ]
          )
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionEnableBankingAuthorizationCompleteResponse"
        run_test!
      end

      response "422", "code missing" do
        let(:body) { { authorization: {} } }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/sophtron/{id}/institutions" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Sophtron provider connection ID"
    parameter name: :query, in: :query, type: :string, required: true, description: "Institution search query. Must be at least 2 characters."

    get "Searches Sophtron institutions" do
      description "Searches Sophtron institutions for mobile bank login setup. Requires a configured Sophtron provider connection and returns a sanitized institution list."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      let(:sophtron_item) do
        user.family.sophtron_items.create!(
          name: "Docs Sophtron",
          user_id: "docs-sophtron-user",
          access_key: "docs-sophtron-access-key",
          customer_id: "customer_docs"
        )
      end
      let(:id) { sophtron_item.id }
      let(:query) { "Chase" }

      response "200", "Sophtron institutions listed" do
        before do
          allow_any_instance_of(Provider::Sophtron).to receive(:search_institutions).and_return([
            {
              InstitutionID: "inst_docs",
              InstitutionName: "Chase Bank",
              Url: "https://chase.example"
            }
          ])
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionSophtronInstitutionsResponse"
        run_test!
      end

      response "422", "query too short" do
        let(:query) { "C" }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/sophtron/{id}/institution" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Sophtron provider connection ID"

    post "Starts Sophtron institution connection" do
      description "Starts a Sophtron bank login job for the selected institution and returns polling state for mobile. Submitted bank credentials are never returned."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[connection],
        properties: {
          connection: {
            type: :object,
            required: %w[institution_id bank_username bank_password],
            properties: {
              institution_id: { type: :string },
              institution_name: { type: :string },
              bank_username: { type: :string },
              bank_password: { type: :string },
              bank_pin: { type: :string },
              new_connection: { type: :boolean, description: "When true, clones credentials into a new provider connection if the selected connection is already tied to an institution." }
            }
          }
        }
      }

      let(:sophtron_item) do
        user.family.sophtron_items.create!(
          name: "Docs Sophtron",
          user_id: "docs-sophtron-user",
          access_key: "docs-sophtron-access-key",
          customer_id: "customer_docs"
        )
      end
      let(:id) { sophtron_item.id }
      let(:body) { { connection: { institution_id: "inst_docs", institution_name: "Chase Bank", bank_username: "bank-user", bank_password: "bank-pass" } } }

      response "201", "Sophtron institution connection started" do
        before do
          allow_any_instance_of(Provider::Sophtron).to receive(:create_user_institution).and_return(
            JobID: "job_docs",
            UserInstitutionID: "user_inst_docs"
          )
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionSophtronConnectResponse"
        run_test!
      end

      response "422", "missing bank credentials" do
        let(:body) { { connection: { institution_id: "inst_docs" } } }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/sophtron/{id}/connection_status" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Sophtron provider connection ID"

    get "Polls Sophtron connection status" do
      description "Polls the active Sophtron job and returns a mobile-safe state. Responses may ask the client to keep polling, collect MFA, or proceed to account setup."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      let(:sophtron_item) do
        user.family.sophtron_items.create!(
          name: "Docs Sophtron",
          user_id: "docs-sophtron-user",
          access_key: "docs-sophtron-access-key",
          customer_id: "customer_docs",
          institution_id: "inst_docs",
          institution_name: "Chase Bank",
          user_institution_id: "user_inst_docs",
          current_job_id: "job_docs"
        )
      end
      let(:id) { sophtron_item.id }

      response "200", "Sophtron status returned" do
        before do
          allow_any_instance_of(Provider::Sophtron).to receive(:get_job_information).and_return(
            LastStatus: "Challenge",
            TokenMethod: [ { name: "SMS", value: "sms" } ].to_json,
            TokenSentFlag: true
          )
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionSophtronStatusResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/sophtron/{id}/mfa" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Sophtron provider connection ID"

    post "Submits Sophtron MFA" do
      description "Submits the MFA answer requested by a Sophtron connection status response. The client should poll connection_status after a successful submission."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[mfa],
        properties: {
          mfa: {
            type: :object,
            required: %w[mfa_type],
            properties: {
              mfa_type: { type: :string, enum: %w[security_answer token_choice token_input verify_phone captcha] },
              security_answers: {
                type: :array,
                items: { type: :string }
              },
              token_choice: { type: :string },
              token_input: { type: :string },
              captcha_input: { type: :string }
            }
          }
        }
      }

      let(:sophtron_item) do
        user.family.sophtron_items.create!(
          name: "Docs Sophtron",
          user_id: "docs-sophtron-user",
          access_key: "docs-sophtron-access-key",
          customer_id: "customer_docs",
          user_institution_id: "user_inst_docs",
          current_job_id: "job_docs"
        )
      end
      let(:id) { sophtron_item.id }
      let(:body) { { mfa: { mfa_type: "token_input", token_input: "123456" } } }

      response "200", "Sophtron MFA submitted" do
        before do
          allow_any_instance_of(Provider::Sophtron).to receive(:update_job_token_input).and_return({})
        end

        schema "$ref" => "#/components/schemas/ProviderConnectionSophtronMfaSubmitResponse"
        run_test!
      end

      response "422", "MFA answer missing" do
        let(:body) { { mfa: { mfa_type: "token_input" } } }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/sophtron/{id}/manual_sync" do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Sophtron provider connection ID"

    patch "Toggles Sophtron manual sync" do
      description "Enables or disables Sophtron manual sync globally, or for linked Sophtron accounts matching one institution key/user institution ID."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          manual_sync: {
            type: :object,
            properties: {
              enabled: { type: :boolean, nullable: true, description: "When omitted, the current target state is toggled." },
              institution_key: { type: :string, nullable: true, description: "Institution key from a Sophtron account." },
              user_institution_id: { type: :string, nullable: true, description: "Sophtron user institution ID. Equivalent to institution_key for most connections." }
            }
          }
        }
      }

      let(:sophtron_item) do
        user.family.sophtron_items.create!(
          name: "Docs Sophtron",
          user_id: "docs-sophtron-user",
          access_key: "docs-sophtron-access-key",
          customer_id: "customer_docs"
        )
      end
      let(:id) { sophtron_item.id }
      let(:body) { { manual_sync: { enabled: true } } }

      response "200", "Sophtron manual sync updated" do
        schema "$ref" => "#/components/schemas/ProviderConnectionSophtronManualSyncResponse"
        run_test!
      end

      response "422", "institution scope has no linked accounts" do
        let(:body) { { manual_sync: { enabled: true, user_institution_id: "missing_inst" } } }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/{provider_key}/{id}/accounts" do
    parameter name: :provider_key, in: :path, type: :string, description: "Provider key from the provider connection status list"
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Provider connection item ID from the provider connection status list"
    parameter name: :unlinked_only, in: :query, type: :boolean, required: false, description: "When true, only provider accounts that still need setup are returned"

    get "Lists discovered provider accounts for setup" do
      description "Lists safe provider-side accounts discovered during provider sync, including linked state, supported Sure account types, and setup suggestions. Requires a read or read_write key and family admin user."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      let(:provider_key) { "mercury" }
      let(:id) { mercury_items(:one).id }
      let(:provider_account) do
        mercury_items(:one).mercury_accounts.create!(
          name: "Docs Mercury Account",
          account_id: "docs_#{SecureRandom.hex(8)}",
          currency: "USD",
          current_balance: BigDecimal("42.50")
        )
      end

      response "200", "provider accounts listed" do
        before { provider_account }

        schema "$ref" => "#/components/schemas/ProviderAccountCollection"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "provider not found" do
        let(:provider_key) { "not_a_provider" }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "connection not found" do
        let(:id) { SecureRandom.uuid }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/{provider_key}/{id}/accounts/{provider_account_id}/link" do
    parameter name: :provider_key, in: :path, type: :string, description: "Provider key from the provider connection status list"
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Provider connection item ID from the provider connection status list"
    parameter name: :provider_account_id, in: :path, type: :string, format: :uuid, description: "Provider-side account ID returned from the provider account setup list"

    post "Links a discovered provider account" do
      description "Links a provider-discovered account to either an existing manual Sure account or a newly created Sure account, then schedules provider sync when possible. Pass account_id to link an existing manual account, or accountable_type/subtype/name/balance/currency to create one. Pass action=skip for providers whose accounts support being ignored."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[provider_account],
        properties: {
          provider_account: {
            type: :object,
            properties: {
              action: { type: :string, enum: %w[skip], description: "Optional; skips the provider account when the provider supports ignored accounts." },
              account_id: { type: :string, format: :uuid, description: "Existing manual Sure account to link." },
              accountable_type: { type: :string, enum: %w[Depository CreditCard Loan Investment Crypto OtherAsset], description: "Sure account type to create when account_id is omitted." },
              subtype: { type: :string, nullable: true },
              name: { type: :string, nullable: true },
              balance: { type: :string, nullable: true },
              cash_balance: { type: :string, nullable: true },
              currency: { type: :string, nullable: true },
              opening_balance_date: { type: :string, format: :date, nullable: true }
            }
          }
        }
      }

      let(:provider_key) { "mercury" }
      let(:id) { mercury_items(:one).id }
      let(:provider_account) do
        mercury_items(:one).mercury_accounts.create!(
          name: "Docs Mercury Account",
          account_id: "docs_link_#{SecureRandom.hex(8)}",
          currency: "USD",
          current_balance: BigDecimal("42.50")
        )
      end
      let(:provider_account_id) { provider_account.id }
      let(:body) { { provider_account: { accountable_type: "Depository", subtype: "checking" } } }

      response "201", "provider account linked to a new account" do
        schema "$ref" => "#/components/schemas/ProviderAccountSetupResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "provider account not found" do
        let(:provider_account_id) { SecureRandom.uuid }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "409", "provider account already linked" do
        before do
          account = Account.create!(
            family: user.family,
            owner: user,
            name: "Docs Manual Account",
            balance: BigDecimal("10"),
            cash_balance: BigDecimal("10"),
            currency: "USD",
            accountable: Depository.new(subtype: Depository::DEFAULT_SUBTYPE)
          )
          AccountProvider.create!(account: account, provider: provider_account)
        end

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "422", "unsupported account type" do
        let(:body) { { provider_account: { accountable_type: "CreditCard" } } }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/sync_all" do
    post "Schedules a sync for all provider connections" do
      description "Schedules a throttled family provider sync job and returns safe provider connection status metadata. Requires a read_write key and family admin user."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "202", "all provider connections sync scheduled" do
        before { user.family.update_column(:last_sync_all_attempted_at, nil) }

        schema "$ref" => "#/components/schemas/ProviderConnectionSyncActionResponse"
        run_test!
      end

      response "200", "sync all was recently requested" do
        before { user.family.update_column(:last_sync_all_attempted_at, Time.current) }

        schema "$ref" => "#/components/schemas/ProviderConnectionSyncActionResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/{provider_key}/sync" do
    parameter name: :provider_key, in: :path, type: :string, description: "Provider key, such as plaid, simplefin, mercury, brex, or snaptrade"

    post "Schedules a sync for one provider" do
      description "Schedules sync jobs for syncable provider items matching the provider key and returns refreshed safe provider connection status metadata. Requires a read_write key and family admin user."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      let(:provider_key) { "mercury" }

      response "202", "provider sync scheduled" do
        schema "$ref" => "#/components/schemas/ProviderConnectionSyncActionResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "provider not found" do
        let(:provider_key) { "not_a_provider" }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/{provider_key}/{id}/sync" do
    parameter name: :provider_key, in: :path, type: :string, description: "Provider key, such as plaid, simplefin, mercury, brex, or snaptrade"
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "Provider connection item ID"

    post "Schedules a sync for one provider connection" do
      description "Schedules a sync for a specific provider connection. Pass mode=balances_only for SimpleFIN to refresh balances without importing full transaction history."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          provider_connection: {
            type: :object,
            properties: {
              mode: { type: :string, enum: %w[full balances_only], default: "full" }
            }
          }
        }
      }

      let(:provider_key) { "mercury" }
      let(:id) { mercury_items(:one).id }
      let(:body) { {} }

      response "202", "provider connection sync scheduled" do
        before { Sync.where(syncable: mercury_items(:one)).delete_all }

        schema "$ref" => "#/components/schemas/ProviderConnectionSyncActionResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "provider connection not found" do
        let(:id) { SecureRandom.uuid }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "422", "unsupported sync mode" do
        let(:body) { { provider_connection: { mode: "balances_only" } } }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end

  path "/api/v1/provider_connections/{provider_key}/{id}/replacement_suggestions/dismiss" do
    parameter name: :provider_key, in: :path, type: :string, description: "Provider key. Only simplefin supports replacement suggestion dismissal."
    parameter name: :id, in: :path, type: :string, format: :uuid, description: "SimpleFIN provider connection item ID"

    post "Dismisses a SimpleFIN replacement suggestion" do
      description "Persists a dismissed SimpleFIN fraud-replacement suggestion pair on the connection's latest sync stats so mobile can hide the same banner as the web app. Requires a read_write key and family admin user."
      tags "Provider Connections"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[replacement_suggestion],
        properties: {
          replacement_suggestion: {
            type: :object,
            required: %w[dormant_sfa_id active_sfa_id],
            properties: {
              dormant_sfa_id: { type: :string, format: :uuid },
              active_sfa_id: { type: :string, format: :uuid }
            }
          }
        }
      }

      let(:provider_key) { "simplefin" }
      let(:simplefin_item) do
        user.family.simplefin_items.create!(
          name: "Docs SimpleFIN",
          access_url: "https://simplefin.example/access"
        )
      end
      let(:dormant_sfa) do
        simplefin_item.simplefin_accounts.create!(
          name: "Old Card",
          account_id: "docs_old_card",
          currency: "USD",
          current_balance: BigDecimal("0"),
          available_balance: BigDecimal("0"),
          account_type: "credit_card"
        )
      end
      let(:active_sfa) do
        simplefin_item.simplefin_accounts.create!(
          name: "New Card",
          account_id: "docs_new_card",
          currency: "USD",
          current_balance: BigDecimal("25"),
          available_balance: BigDecimal("25"),
          account_type: "credit_card"
        )
      end
      let!(:latest_sync) do
        simplefin_item.syncs.create!(
          status: "completed",
          sync_stats: {
            "replacement_suggestions" => [
              {
                "dormant_sfa_id" => dormant_sfa.id,
                "active_sfa_id" => active_sfa.id
              }
            ]
          }
        )
      end
      let(:id) { simplefin_item.id }
      let(:body) do
        {
          replacement_suggestion: {
            dormant_sfa_id: dormant_sfa.id,
            active_sfa_id: active_sfa.id
          }
        }
      end

      response "200", "replacement suggestion dismissed" do
        schema "$ref" => "#/components/schemas/ProviderConnectionReplacementSuggestionDismissalResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "404", "provider not supported" do
        let(:provider_key) { "mercury" }
        let(:id) { mercury_items(:one).id }

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "422", "replacement account pair invalid" do
        let(:body) do
          {
            replacement_suggestion: {
              dormant_sfa_id: dormant_sfa.id,
              active_sfa_id: SecureRandom.uuid
            }
          }
        end

        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end
end
