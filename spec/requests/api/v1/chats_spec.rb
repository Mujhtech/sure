# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Chats', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      ai_enabled: true
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:chat) do
    user.chats.create!(title: 'Budget planning').tap do |record|
      record.messages.create!(
        type: 'UserMessage',
        content: 'How should I budget for a vacation?',
        ai_model: 'gpt-4'
      )

      assistant_message = record.messages.create!(
        type: 'AssistantMessage',
        content: "Let's review your spending patterns first.",
        ai_model: 'gpt-4'
      )

      assistant_message.tool_calls.create!(
        provider_id: 'openai',
        type: 'ToolCall::Function',
        function_name: 'get_accounts',
        function_arguments: { 'scope' => 'spending' },
        function_result: { 'total_spend' => 1500 }
      )

      record.messages.create!(
        type: 'AssistantMessage',
        content: 'Does this align with your savings goals?',
        ai_model: 'gpt-4'
      )
    end
  end

  let!(:another_chat) do
    user.chats.create!(title: 'Retirement planning').tap do |record|
      record.messages.create!(
        type: 'UserMessage',
        content: 'How much should I contribute to my IRA?',
        ai_model: 'gpt-4'
      )
    end
  end

  path '/api/v1/chats' do
    get 'List chats' do
      tags 'Chats'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'chats listed' do
        schema '$ref' => '#/components/schemas/ChatCollection'

        run_test!
      end

      response '403', 'AI features disabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:user) do
          family.users.create!(
            email: 'no-ai@example.com',
            password: 'password123',
            password_confirmation: 'password123',
            ai_enabled: false
          )
        end

        run_test!
      end
    end

    post 'Create chat' do
      tags 'Chats'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :chat_params, in: :body, required: true, schema: {
        type: :object,
        properties: {
          title: { type: :string, example: 'Monthly budget review' },
          message: { type: :string, description: 'Optional initial message in the chat. When title is omitted, the server generates the title from this message.' },
          model: { type: :string, description: 'Optional OpenAI model identifier' }
        }
      }

      let(:chat_params) do
        {
          message: 'Can you help me plan a summer trip?',
          model: 'gpt-4-turbo'
        }
      end

      response '201', 'chat created' do
        schema '$ref' => '#/components/schemas/ChatDetail'

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:chat_params) { { title: '' } }

        run_test!
      end
    end
  end

  path '/api/v1/chats/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Chat ID'

    get 'Retrieve a chat' do
      tags 'Chats'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { chat.id }

      response '200', 'chat retrieved' do
        schema '$ref' => '#/components/schemas/ChatDetail'

        run_test!
      end

      response '404', 'chat not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update a chat' do
      tags 'Chats'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'

      let(:id) { chat.id }

      parameter name: :chat_params, in: :body, required: true, schema: {
        type: :object,
        properties: {
          title: { type: :string, example: 'Updated chat title' }
        }
      }

      let(:chat_params) { { title: 'Updated budget plan' } }

      response '200', 'chat updated' do
        schema '$ref' => '#/components/schemas/ChatDetail'

        run_test!
      end

      response '404', 'chat not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:chat_params) { { title: '' } }

        run_test!
      end
    end

    delete 'Delete a chat' do
      tags 'Chats'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { another_chat.id }

      response '204', 'chat deleted' do
        run_test!
      end

      response '404', 'chat not found' do
        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/chats/{id}/updates' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Chat ID'
    parameter name: :since, in: :query, type: :string, required: false,
              description: 'ISO8601 cursor from the previous poll (server_time). Omit to fetch all messages.'

    get 'Poll a chat for updates' do
      tags 'Chats'
      description 'Incremental polling endpoint. Returns messages created or updated since the given cursor, ' \
                  'plus whether an assistant response is still pending. Pass the returned server_time as the ' \
                  'since parameter on the next poll and upsert messages by id (the window is inclusive).'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { chat.id }
      let(:since) { nil }

      response '200', 'chat updates returned' do
        schema '$ref' => '#/components/schemas/ChatUpdates'

        run_test!
      end

      response '422', 'invalid cursor' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:since) { 'not-a-timestamp' }

        run_test!
      end

      response '404', 'chat not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/chats/{chat_id}/messages' do
    parameter name: :chat_id, in: :path, type: :string, required: true, description: 'Chat ID'

    post 'Create a message' do
      tags 'Chat Messages'
      description 'Creates a user message and triggers an asynchronous AI response. ' \
                  'Also accepts multipart/form-data with an optional `file` part (max 25MB): PDFs are queued ' \
                  'as bank statement imports, other supported documents go to the family document store, and ' \
                  'the attachment metadata is returned on the message. Provide `content`, `file`, or both.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json', 'multipart/form-data'
      produces 'application/json'

      let(:chat_id) { chat.id }

      parameter name: :message_params, in: :body, required: true, schema: {
        type: :object,
        properties: {
          content: { type: :string },
          model: { type: :string },
          file: { type: :string, format: :binary, description: 'Optional attachment (multipart/form-data only)' }
        }
      }

      let(:message_params) do
        {
          content: 'Please summarise the last conversation.',
          model: 'gpt-4'
        }
      end

      response '201', 'message created' do
        schema '$ref' => '#/components/schemas/MessageResponse'

        run_test!
      end

      response '404', 'chat not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:chat_id) { SecureRandom.uuid }

        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:message_params) { { content: '' } }

        run_test!
      end
    end
  end

  path '/api/v1/chats/{chat_id}/messages/retry' do
    parameter name: :chat_id, in: :path, type: :string, required: true, description: 'Chat ID'

    post 'Retry the last user message' do
      tags 'Chat Messages'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:chat_id) { chat.id }

      response '202', 'retry started' do
        schema '$ref' => '#/components/schemas/RetryResponse'

        before do
          chat.messages.destroy_all
          chat.messages.create!(
            type: 'UserMessage',
            content: 'Please try that again.',
            ai_model: 'gpt-4'
          )
          chat.messages.where(type: 'AssistantMessage').destroy_all
          chat.update!(error: { message: 'Provider failed' }.to_json)
        end

        run_test!
      end

      response '404', 'chat not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:chat_id) { SecureRandom.uuid }

        run_test!
      end

      response '422', 'no user message available' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:chat) do
          user.chats.create!(title: 'Empty conversation')
        end

        let(:chat_id) { chat.id }

        run_test!
      end
    end
  end

  path '/api/v1/chats/{chat_id}/messages/{id}/report_timeout' do
    parameter name: :chat_id, in: :path, type: :string, required: true, description: 'Chat ID'
    parameter name: :id, in: :path, type: :string, required: true, description: 'Message ID'

    post 'Report an undelivered assistant response' do
      tags 'Chat Messages'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:chat_id) { chat.id }
      let(:timed_out_message) do
        chat.messages.create!(
          type: 'AssistantMessage',
          content: '',
          ai_model: 'gpt-4',
          status: :pending
        ).tap do |message|
          message.update_columns(created_at: 2.minutes.ago, updated_at: 2.minutes.ago)
        end
      end
      let(:id) { timed_out_message.id }

      response '200', 'timeout report accepted' do
        schema '$ref' => '#/components/schemas/MessageTimeoutReportResponse'

        run_test!
      end

      response '404', 'message not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/chats/{chat_id}/messages/{id}/attachment' do
    parameter name: :chat_id, in: :path, type: :string, required: true, description: 'Chat ID'
    parameter name: :id, in: :path, type: :string, required: true, description: 'Message ID'

    get 'Download a message attachment' do
      tags 'Chat Messages'
      description 'Redirects to the attached file. Pass disposition=attachment to force download.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:chat_id) { chat.id }

      response '302', 'redirects to the file' do
        let(:id) do
          message = chat.messages.create!(type: 'UserMessage', content: 'see attached', ai_model: 'gpt-4')
          message.attachment.attach(io: StringIO.new('hello'), filename: 'note.txt', content_type: 'text/plain')
          message.save!
          message.id
        end

        run_test!
      end

      response '404', 'message has no attachment' do
        let(:id) do
          chat.messages.create!(type: 'UserMessage', content: 'no file', ai_model: 'gpt-4').id
        end

        run_test!
      end
    end
  end
end
