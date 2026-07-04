# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Auth', type: :request do
  path '/api/v1/auth/signup' do
    post 'Sign up a new user' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              email: { type: :string, format: :email, description: 'User email address' },
              password: { type: :string, description: 'Password (min 8 chars, mixed case, number, special char)' },
              first_name: { type: :string },
              last_name: { type: :string }
            },
            required: %w[email password]
          },
          device: {
            type: :object,
            properties: {
              device_id: { type: :string, description: 'Unique device identifier' },
              device_name: { type: :string, description: 'Human-readable device name' },
              device_type: { type: :string, description: 'Device type (e.g. ios, android)' },
              os_version: { type: :string },
              app_version: { type: :string }
            },
            required: %w[device_id device_name device_type os_version app_version]
          },
          invite_code: { type: :string, nullable: true, description: 'Invite code (required when invites are enforced)' },
          invitation_token: { type: :string, nullable: true, description: 'Family invitation token. When provided, the new user joins the invited family instead of creating a new family.' }
        },
        required: %w[user device]
      }

      response '201', 'user created' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '422', 'validation error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '403', 'invite code required or invalid' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end

  path '/api/v1/auth/login' do
    post 'Log in with email and password' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          email: { type: :string, format: :email },
          password: { type: :string },
          otp_code: { type: :string, nullable: true, description: 'TOTP code if MFA is enabled' },
          invitation_token: { type: :string, nullable: true, description: 'Family invitation token to accept after successful authentication.' },
          device: {
            type: :object,
            properties: {
              device_id: { type: :string },
              device_name: { type: :string },
              device_type: { type: :string },
              os_version: { type: :string },
              app_version: { type: :string }
            },
            required: %w[device_id device_name device_type os_version app_version]
          }
        },
        required: %w[email password device]
      }

      response '200', 'login successful' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '401', 'invalid credentials or MFA required' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end

  path '/api/v1/auth/webauthn_options' do
    post 'Create WebAuthn MFA authentication options' do
      tags 'Auth'
      description 'After validating email and password, creates short-lived WebAuthn authentication options for accounts that require MFA and have registered passkeys/security keys.'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[email password],
        properties: {
          email: { type: :string, format: :email },
          password: { type: :string }
        }
      }

      let(:family) do
        Family.create!(
          name: 'WebAuthn Auth Family',
          currency: 'USD',
          locale: 'en',
          date_format: '%m-%d-%Y'
        )
      end
      let(:webauthn_user) do
        family.users.create!(
          email: 'webauthn-auth@example.com',
          password: 'password123',
          password_confirmation: 'password123',
          role: 'admin'
        )
      end
      let(:body) { { email: webauthn_user.email, password: 'password123' } }

      response '200', 'WebAuthn MFA options created' do
        schema type: :object,
               required: %w[challenge_id expires_in_seconds public_key],
               properties: {
                 challenge_id: { type: :string, format: :uuid },
                 expires_in_seconds: { type: :integer },
                 public_key: {
                   type: :object,
                   additionalProperties: true,
                   description: 'PublicKeyCredentialRequestOptions returned by the WebAuthn library.'
                 }
               }

        before do
          webauthn_user.setup_mfa!
          webauthn_user.enable_mfa!
          webauthn_user.webauthn_credentials.create!(
            credential_id: 'docs-credential-id',
            public_key: 'docs-public-key',
            sign_count: 0
          )
          options = double('WebAuthnRequestOptions', challenge: 'docs-challenge')
          allow(options).to receive(:as_json).and_return({ challenge: 'docs-challenge', allowCredentials: [ { id: 'docs-credential-id' } ] })
          allow_any_instance_of(WebAuthn::RelyingParty).to receive(:options_for_authentication).and_return(options)
        end

        run_test!
      end

      response '401', 'invalid credentials' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { email: webauthn_user.email, password: 'wrong-password' } }

        run_test!
      end
    end
  end

  path '/api/v1/auth/webauthn_verify' do
    post 'Verify WebAuthn MFA assertion and log in' do
      tags 'Auth'
      description 'Verifies a WebAuthn authentication assertion from the options endpoint and issues the normal mobile OAuth token response.'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[email password challenge_id credential device],
        properties: {
          email: { type: :string, format: :email },
          password: { type: :string },
          challenge_id: { type: :string, format: :uuid },
          credential: {
            type: :object,
            additionalProperties: true,
            description: 'PublicKeyCredential assertion returned by the platform authenticator.'
          },
          invitation_token: { type: :string, nullable: true, description: 'Family invitation token to accept after successful authentication.' },
          device: {
            type: :object,
            required: %w[device_id device_name device_type os_version app_version],
            properties: {
              device_id: { type: :string },
              device_name: { type: :string },
              device_type: { type: :string },
              os_version: { type: :string },
              app_version: { type: :string }
            }
          }
        }
      }

      let(:family) do
        Family.create!(
          name: 'WebAuthn Verify Family',
          currency: 'USD',
          locale: 'en',
          date_format: '%m-%d-%Y'
        )
      end
      let(:webauthn_user) do
        family.users.create!(
          email: 'webauthn-verify@example.com',
          password: 'password123',
          password_confirmation: 'password123',
          role: 'admin'
        )
      end
      let(:challenge_id) { SecureRandom.uuid }
      let(:credential_payload) do
        {
          id: 'docs-credential-id',
          rawId: 'docs-credential-id',
          type: 'public-key',
          response: {
            authenticatorData: 'authenticator-data',
            clientDataJSON: 'client-data-json',
            signature: 'signature'
          }
        }
      end
      let(:body) do
        {
          email: webauthn_user.email,
          password: 'password123',
          challenge_id: challenge_id,
          credential: credential_payload,
          device: {
            device_id: 'docs-device-id',
            device_name: 'Docs iPhone',
            device_type: 'ios',
            os_version: '17.0',
            app_version: '1.0.0'
          }
        }
      end

      response '200', 'WebAuthn MFA login successful' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }

        before do
          webauthn_user.setup_mfa!
          webauthn_user.enable_mfa!
          webauthn_user.webauthn_credentials.create!(
            credential_id: 'docs-credential-id',
            public_key: 'docs-public-key',
            sign_count: 0
          )
          Rails.cache.write("api:v1:webauthn_authentication:#{webauthn_user.id}:#{challenge_id}", 'docs-challenge')
          verified_credential = double('WebAuthnCredential', id: 'docs-credential-id', sign_count: 1)
          allow(verified_credential).to receive(:verify)
          allow(WebAuthn::Credential).to receive(:from_get).and_return(verified_credential)
        end

        run_test!
      end

      response '422', 'challenge expired or credential invalid' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        run_test!
      end
    end
  end

  path '/api/v1/auth/password_reset' do
    post 'Request password reset' do
      tags 'Auth'
      description 'Requests a password reset email for local-password users. Always returns an accepted generic response when password reset is enabled to avoid account enumeration.'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[email],
        properties: {
          email: { type: :string, format: :email }
        }
      }

      let(:body) { { email: 'api-user@example.com' } }

      response '202', 'password reset requested if account exists' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end

      response '403', 'password reset disabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow(AuthConfig).to receive(:password_features_enabled?).and_return(false)
        end

        run_test!
      end
    end

    patch 'Reset password with token' do
      tags 'Auth'
      description 'Sets a new password using a password reset token from email. SSO-only users cannot set a password through this endpoint.'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[token user],
        properties: {
          token: { type: :string },
          user: {
            type: :object,
            required: %w[password password_confirmation],
            properties: {
              password: { type: :string },
              password_confirmation: { type: :string }
            }
          }
        }
      }

      let(:body) do
        {
          token: 'password-reset-token',
          user: {
            password: 'new-password',
            password_confirmation: 'new-password'
          }
        }
      end

      response '200', 'password reset' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end

      response '422', 'invalid token or validation failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        run_test!
      end
    end
  end

  path '/api/v1/auth/email_confirmation' do
    post 'Confirm pending email change' do
      tags 'Auth'
      description 'Confirms a pending email change using the token from the confirmation email.'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[token],
        properties: {
          token: { type: :string }
        }
      }

      let(:body) { { token: 'email-confirmation-token' } }

      response '200', 'email confirmed' do
        schema type: :object,
               required: %w[message user],
               properties: {
                 message: { type: :string },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string, format: :email },
                     first_name: { type: :string, nullable: true },
                     last_name: { type: :string, nullable: true },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }

        run_test!
      end

      response '422', 'invalid token' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        run_test!
      end
    end
  end

  path '/api/v1/auth/email_confirmation/resend' do
    post 'Resend pending email confirmation' do
      tags 'Auth'
      description 'Resends the confirmation email for the authenticated user pending email change. Requires a read_write API key or OAuth token.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '202', 'confirmation email sent' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end

      response '403', 'forbidden - requires read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        run_test!
      end

      response '422', 'no pending email change' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        run_test!
      end
    end
  end

  path '/api/v1/auth/sso_exchange' do
    post 'Exchange mobile SSO authorization code for tokens' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      description 'Exchanges a one-time authorization code (received via deep link after mobile SSO) for OAuth tokens. The code is single-use and expires after 5 minutes.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          code: { type: :string, description: 'One-time authorization code from mobile SSO callback' }
        },
        required: %w[code]
      }

      response '200', 'tokens issued' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '401', 'invalid or expired code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end

  path '/api/v1/auth/refresh' do
    post 'Refresh an access token' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          refresh_token: { type: :string, description: 'The refresh token from a previous login or refresh' },
          device: {
            type: :object,
            properties: {
              device_id: { type: :string }
            },
            required: %w[device_id]
          }
        },
        required: %w[refresh_token device]
      }

      response '200', 'token refreshed' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer }
               }
        run_test!
      end

      response '401', 'invalid refresh token' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '400', 'missing refresh token' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end

  path '/api/v1/auth/sso_link' do
    post 'Link an existing account via SSO' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      description 'Authenticates with email/password and links the SSO identity from a previously issued linking code. Creates an OidcIdentity, logs the link via SsoAuditLog, and issues mobile OAuth tokens.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          linking_code: { type: :string, description: 'One-time linking code from mobile SSO onboarding redirect' },
          email: { type: :string, format: :email, description: 'Email of the existing account to link' },
          password: { type: :string, description: 'Password for the existing account' }
        },
        required: %w[linking_code email password]
      }

      response '200', 'account linked and tokens issued' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '400', 'missing linking code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '401', 'invalid credentials or expired linking code' do
        schema oneOf: [
          { '$ref' => '#/components/schemas/ErrorResponse' },
          { '$ref' => '#/components/schemas/MfaRequiredResponse' }
        ]
        run_test!
      end
    end
  end

  path '/api/v1/auth/sso_create_account' do
    post 'Create a new account via SSO' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      description 'Creates a new user and family from a previously issued linking code. Links the SSO identity via OidcIdentity, logs the JIT account creation via SsoAuditLog, and issues mobile OAuth tokens. The linking code must have allow_account_creation enabled.'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          linking_code: { type: :string, description: 'One-time linking code from mobile SSO onboarding redirect' },
          first_name: { type: :string, description: 'First name (overrides value from SSO provider if provided)' },
          last_name: { type: :string, description: 'Last name (overrides value from SSO provider if provided)' }
        },
        required: %w[linking_code]
      }

      response '200', 'account created and tokens issued' do
        schema type: :object,
               properties: {
                 access_token: { type: :string },
                 refresh_token: { type: :string },
                 token_type: { type: :string },
                 expires_in: { type: :integer },
                 created_at: { type: :integer },
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string },
                     last_name: { type: :string },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '400', 'missing linking code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '401', 'invalid or expired linking code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '403', 'account creation disabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '422', 'user validation error' do
        schema type: :object,
               properties: {
                 errors: {
                   type: :array,
                   items: { type: :string }
                 }
               }
        run_test!
      end
    end
  end

  path '/api/v1/auth/enable_ai' do
    patch 'Enable AI features for the authenticated user' do
      tags 'Auth'
      consumes 'application/json'
      produces 'application/json'
      security [ { apiKeyAuth: [] } ]

      response '200', 'ai enabled' do
        schema type: :object,
               properties: {
                 user: {
                   type: :object,
                   properties: {
                     id: { type: :string, format: :uuid },
                     email: { type: :string },
                     first_name: { type: :string, nullable: true },
                     last_name: { type: :string, nullable: true },
                     ui_layout: { type: :string, enum: %w[dashboard intro] },
                     ai_enabled: { type: :boolean }
                   }
                 }
               }
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end
end
