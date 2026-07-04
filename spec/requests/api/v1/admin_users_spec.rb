# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Admin Users', type: :request do
  let(:family) do
    Family.create!(
      name: 'Admin Users Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:support_family) do
    Family.create!(
      name: 'Support Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    support_family.users.create!(
      email: 'admin-users-super@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'super_admin'
    )
  end

  let(:target_user) do
    family.users.create!(
      email: 'admin-users-target@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'member'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Admin Users Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'mobile'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Admin Users Read Docs Key',
      key: key,
      scopes: %w[read],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/admin/users' do
    get 'List admin users' do
      tags 'Admin Users'
      description 'Lists users grouped by family with subscription, account, transaction, session, and pending invitation metadata. Requires a read-capable credential owned by a super admin.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :role, in: :query, required: false,
                schema: { type: :string, enum: %w[guest member admin super_admin] }
      parameter name: :trial_status, in: :query, required: false,
                schema: { type: :string, enum: %w[expiring_soon trialing] }

      let(:'X-Api-Key') { read_only_api_key.plain_key }

      response '200', 'admin users listed' do
        schema '$ref' => '#/components/schemas/AdminUserCollection'

        before do
          target_user
        end

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end
    end
  end

  path '/api/v1/admin/users/{id}' do
    parameter name: :id, in: :path, required: true, description: 'User ID',
              schema: { type: :string, format: :uuid }

    let(:id) { target_user.id }

    patch 'Update admin user role' do
      tags 'Admin Users'
      description 'Updates another user role. Super admins cannot change their own role through this endpoint.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :user_params, in: :body, schema: { '$ref' => '#/components/schemas/AdminUserUpdateRequest' }

      let(:user_params) do
        {
          user: {
            role: 'admin'
          }
        }
      end

      response '200', 'admin user role updated' do
        schema '$ref' => '#/components/schemas/AdminUserResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '404', 'user not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
