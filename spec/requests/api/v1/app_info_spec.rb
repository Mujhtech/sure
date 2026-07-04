# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 App Info', type: :request do
  path '/api/v1/app_info' do
    get 'Retrieve public app metadata' do
      tags 'App Info'
      description 'Returns public application metadata, legal links, support links, and related API paths for native app launch/about screens.'
      produces 'application/json'

      response '200', 'app metadata retrieved' do
        schema '$ref' => '#/components/schemas/AppInfoResponse'

        run_test!
      end
    end
  end

  path '/api/v1/app_info/changelog' do
    get 'Retrieve latest changelog entry' do
      tags 'App Info'
      description 'Returns the same latest GitHub release notes shown by the web changelog page as HTML suitable for native rendering.'
      produces 'application/json'

      before do
        allow(Provider::Registry).to receive(:get_provider).with(:github).and_return(
          double(
            fetch_latest_release_notes: {
              avatar: 'https://example.com/avatar.png',
              username: 'release-user',
              name: 'Mobile API Release',
              published_at: Time.zone.parse('2026-06-01 12:00:00 UTC'),
              body: '<p>New mobile APIs.</p>'
            }
          )
        )
      end

      response '200', 'changelog retrieved' do
        schema '$ref' => '#/components/schemas/AppInfoChangelogResponse'

        run_test!
      end
    end
  end

  path '/api/v1/app_info/feedback' do
    get 'Retrieve public feedback links' do
      tags 'App Info'
      description 'Returns public support and feedback destinations used by the web feedback page.'
      produces 'application/json'

      response '200', 'feedback links retrieved' do
        schema '$ref' => '#/components/schemas/AppInfoFeedbackResponse'

        run_test!
      end
    end
  end
end
