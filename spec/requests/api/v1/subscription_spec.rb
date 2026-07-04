# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Subscription', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Subscription Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-subscription@example.com',
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
      name: 'Subscription Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'mobile'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Subscription Read Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:stripe_provider) { instance_double('Provider::Stripe') }
  let(:checkout_session) { Struct.new(:url, :customer_id).new('https://checkout.example/session', 'cus_docs_123') }
  let(:'X-Api-Key') { api_key.plain_key }

  before do
    allow(Rails.configuration.app_mode).to receive(:self_hosted?).and_return(false)
    allow(Provider::Registry).to receive(:get_provider).with(:stripe).and_return(stripe_provider)
    allow(stripe_provider).to receive(:create_checkout_session).and_return(checkout_session)
    allow(stripe_provider).to receive(:create_payment_portal_session_url).and_return('https://billing.example/session')
  end

  path '/api/v1/subscription' do
    get 'Show subscription state' do
      tags 'Subscription'
      description 'Returns mobile subscription state, trial/paywall flags, and billing action availability.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'subscription state returned' do
        schema '$ref' => '#/components/schemas/SubscriptionResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end
    end
  end

  path '/api/v1/subscription/start_trial' do
    post 'Start subscription trial' do
      tags 'Subscription'
      description 'Starts the offline trial subscription when available. Disabled for self-hosted instances.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'trial started' do
        schema '$ref' => '#/components/schemas/SubscriptionResponse'

        run_test!
      end

      response '422', 'trial already used' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          family.create_subscription!(status: 'trialing', trial_ends_at: 10.days.from_now)
        end

        run_test!
      end
    end
  end

  path '/api/v1/subscription/checkout' do
    post 'Create checkout session' do
      tags 'Subscription'
      description 'Creates a Stripe checkout session and returns its URL for native clients to open.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          plan: { type: :string, enum: %w[monthly annual], default: 'annual' }
        }
      }

      let(:body) { { plan: 'annual' } }

      response '201', 'checkout session created' do
        schema '$ref' => '#/components/schemas/SubscriptionCheckoutResponse'

        run_test!
      end

      response '422', 'invalid plan' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { plan: 'lifetime' } }

        run_test!
      end
    end
  end

  path '/api/v1/subscription/portal' do
    post 'Create billing portal session' do
      tags 'Subscription'
      description 'Creates a Stripe billing portal session and returns its URL for native clients to open.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'billing portal session created' do
        schema '$ref' => '#/components/schemas/SubscriptionPortalResponse'

        before do
          family.update!(stripe_customer_id: 'cus_docs_123')
        end

        run_test!
      end

      response '422', 'billing portal unavailable' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        run_test!
      end
    end
  end
end
