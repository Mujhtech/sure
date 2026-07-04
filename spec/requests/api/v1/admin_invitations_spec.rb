# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Admin Invitations', type: :request do
  let(:family) do
    Family.create!(
      name: 'Admin Invitations Family',
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

  let(:admin_user) do
    family.users.create!(
      email: 'admin-invites-family-admin@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'admin'
    )
  end

  let(:user) do
    support_family.users.create!(
      email: 'admin-invites-super@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'super_admin'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Admin Invitations Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'mobile'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Admin Invitations Read Docs Key',
      key: key,
      scopes: %w[read],
      source: 'web'
    )
  end

  let(:invitation) do
    Invitation.create!(
      family: family,
      inviter: admin_user,
      email: 'pending-docs@example.com',
      role: 'member'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/admin/invitations/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Invitation ID',
              schema: { type: :string, format: :uuid }

    let(:id) { invitation.id }

    delete 'Delete admin invitation' do
      tags 'Admin Invitations'
      description 'Deletes a pending or historical invitation by ID. Requires a read_write credential owned by a super admin.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'invitation deleted' do
        schema '$ref' => '#/components/schemas/AdminInvitationDeleteResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '404', 'invitation not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/admin/families/{id}/invitations' do
    parameter name: :id, in: :path, required: true, description: 'Family ID',
              schema: { type: :string, format: :uuid }

    let(:id) { family.id }

    delete 'Delete all pending admin family invitations' do
      tags 'Admin Invitations'
      description 'Deletes all currently pending invitations for a family. Accepted or expired invitations are left untouched.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'pending invitations deleted' do
        schema '$ref' => '#/components/schemas/AdminFamilyInvitationsDeleteResponse'

        before do
          invitation
        end

        run_test!
      end
    end
  end
end
