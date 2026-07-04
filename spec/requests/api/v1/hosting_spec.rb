# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Hosting', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Hosting Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-hosting@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'admin',
      onboarded_at: Time.current
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Hosting Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'mobile'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Hosting Read Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  before do
    allow(Rails.configuration.app_mode).to receive(:self_hosted?).and_return(true)
    allow(AutoSyncScheduler).to receive(:sync!)
  end

  path '/api/v1/hosting' do
    get 'Show self-hosting settings' do
      tags 'Hosting'
      description 'Returns self-hosting configuration state for mobile settings screens. Secret values are represented only by configured/env_locked flags.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'hosting settings returned' do
        schema '$ref' => '#/components/schemas/HostingResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '403', 'feature disabled outside self-hosted mode' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow(Rails.configuration.app_mode).to receive(:self_hosted?).and_return(false)
        end

        run_test!
      end
    end

    patch 'Update self-hosting settings' do
      tags 'Hosting'
      description 'Updates admin-managed self-hosting settings. Secret fields ignore blank values and redacted placeholders.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          setting: {
            type: :object,
            properties: {
              openai_access_token: { type: :string },
              openai_uri_base: { type: :string, nullable: true },
              openai_model: { type: :string, nullable: true },
              openai_json_mode: { type: :string, enum: %w[strict none json_object auto], nullable: true },
              anthropic_access_token: { type: :string },
              anthropic_base_url: { type: :string, nullable: true },
              anthropic_model: { type: :string, nullable: true },
              llm_provider: { type: :string, enum: %w[openai anthropic] },
              exchange_rate_provider: { type: :string },
              securities_providers: { type: :array, items: { type: :string } },
              syncs_include_pending: { type: :boolean },
              auto_sync_enabled: { type: :boolean },
              auto_sync_time: { type: :string },
              external_assistant_url: { type: :string, nullable: true },
              external_assistant_token: { type: :string },
              external_assistant_agent_id: { type: :string, nullable: true }
            }
          },
          family: {
            type: :object,
            properties: {
              assistant_type: { type: :string, enum: %w[builtin external] }
            }
          }
        }
      }

      let(:body) do
        {
          setting: {
            openai_model: 'gpt-4',
            llm_provider: 'openai',
            auto_sync_time: '03:15'
          }
        }
      end

      response '200', 'hosting settings updated' do
        schema '$ref' => '#/components/schemas/HostingMutationResponse'

        run_test!
      end

      response '403', 'forbidden - requires admin or self-hosted mode' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '422', 'validation failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { setting: { auto_sync_time: '99:99' } } }

        run_test!
      end
    end
  end

  path '/api/v1/hosting/clear_cache' do
    delete 'Queue data cache clear' do
      tags 'Hosting'
      description 'Queues a cache clear for exchange rates, balances, holdings, and security prices for the current family.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'cache clear queued' do
        schema '$ref' => '#/components/schemas/HostingMutationResponse'

        run_test!
      end
    end
  end

  path '/api/v1/hosting/disconnect_external_assistant' do
    delete 'Disconnect external assistant' do
      tags 'Hosting'
      description 'Clears external assistant settings and resets the family assistant type to builtin unless ASSISTANT_TYPE is environment-managed.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'external assistant disconnected' do
        schema '$ref' => '#/components/schemas/HostingMutationResponse'

        run_test!
      end
    end
  end
end
