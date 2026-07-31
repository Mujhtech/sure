require "test_helper"

class Api::V1::AuthControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Clean up any existing invite codes
    InviteCode.destroy_all
    @device_info = {
      device_id: "test-device-123",
      device_name: "Test iPhone",
      device_type: "ios",
      os_version: "17.0",
      app_version: "1.0.0"
    }

    # Ensure the shared OAuth application exists
    @shared_app = Doorkeeper::Application.find_or_create_by!(name: "Sure Mobile") do |app|
      app.redirect_uri = "sureapp://oauth/callback"
      app.scopes = "read read_write"
      app.confidential = false
    end
    @shared_app.update!(scopes: "read read_write")

    # Clear the memoized class variable so it picks up the test record
    MobileDevice.instance_variable_set(:@shared_oauth_application, nil)

    # Use a real cache store for SSO linking tests (test env uses :null_store by default)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache if @original_cache
  end

  test "should signup new user and return OAuth tokens" do
    assert_difference("User.count", 1) do
      assert_difference("MobileDevice.count", 1) do
        assert_no_difference("Doorkeeper::Application.count") do
          assert_difference("Doorkeeper::AccessToken.count", 1) do
            post "/api/v1/auth/signup", params: {
              user: {
                email: "newuser@example.com",
                password: "SecurePass123!",
                first_name: "New",
                last_name: "User"
              },
              device: @device_info
            }
          end
        end
      end
    end

    assert_response :created
    response_data = JSON.parse(response.body)

    assert response_data["user"]["id"].present?
    assert_equal "newuser@example.com", response_data["user"]["email"]
    assert_equal "New", response_data["user"]["first_name"]
    assert_equal "User", response_data["user"]["last_name"]
    new_user = User.find(response_data["user"]["id"])
    assert_equal new_user.ui_layout, response_data["user"]["ui_layout"]
    assert_equal new_user.ai_enabled?, response_data["user"]["ai_enabled"]

    # OAuth token assertions
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
    assert_equal "Bearer", response_data["token_type"]
    assert_equal 2592000, response_data["expires_in"] # 30 days
    assert response_data["created_at"].present?

    # Verify the device was created
    created_user = User.find(response_data["user"]["id"])
    device = created_user.mobile_devices.first
    assert_equal @device_info[:device_id], device.device_id
    assert_equal @device_info[:device_name], device.device_name
    assert_equal @device_info[:device_type], device.device_type
  end

  test "should not signup without device info" do
    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "newuser@example.com",
          password: "SecurePass123!",
          first_name: "New",
          last_name: "User"
        }
      }
    end

    assert_response :bad_request
    response_data = JSON.parse(response.body)
    assert_equal "Device information is required", response_data["error"]
  end

  test "should reject signup with invalid device_type before committing any state" do
    # Pre-validation catches bad device_type and returns 400 without creating
    # user/family/device/token. Guards against a partial-commit state where the
    # account exists but the mobile session handoff fails.
    assert_no_difference([ "User.count", "MobileDevice.count", "Doorkeeper::AccessToken.count" ]) do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "newuser@example.com",
          password: "SecurePass123!",
          first_name: "New",
          last_name: "User"
        },
        device: @device_info.merge(device_type: "windows") # not in allowlist
      }
    end

    assert_response :bad_request
  end

  test "should not signup with invalid password" do
    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "newuser@example.com",
          password: "weak",
          first_name: "New",
          last_name: "User"
        },
        device: @device_info
      }
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert response_data["errors"].include?("Password must be at least 8 characters")
  end

  test "should not signup with duplicate email" do
    existing_user = users(:family_admin)

    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: existing_user.email,
          password: "SecurePass123!",
          first_name: "Duplicate",
          last_name: "User"
        },
        device: @device_info
      }
    end

    assert_response :unprocessable_entity
  end

  test "should create user with admin role and family" do
    post "/api/v1/auth/signup", params: {
      user: {
        email: "newuser@example.com",
        password: "SecurePass123!",
        first_name: "New",
        last_name: "User"
      },
      device: @device_info
    }

    assert_response :created
    response_data = JSON.parse(response.body)

    new_user = User.find(response_data["user"]["id"])
    assert_equal "admin", new_user.role
    assert new_user.family.present?
  end

  test "should require invite code when enabled" do
    # Mock invite code requirement
    Api::V1::AuthController.any_instance.stubs(:invite_code_required?).returns(true)

    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "newuser@example.com",
          password: "SecurePass123!",
          first_name: "New",
          last_name: "User"
        },
        device: @device_info
      }
    end

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_equal "Invite code is required", response_data["error"]
  end

  test "should signup with valid invite code when required" do
    # Create a valid invite code
    invite_code = InviteCode.create!

    # Mock invite code requirement
    Api::V1::AuthController.any_instance.stubs(:invite_code_required?).returns(true)

    assert_difference("User.count", 1) do
      assert_difference("InviteCode.count", -1) do
        post "/api/v1/auth/signup", params: {
          user: {
            email: "newuser@example.com",
            password: "SecurePass123!",
            first_name: "New",
            last_name: "User"
          },
          device: @device_info,
          invite_code: invite_code.token
        }
      end
    end

    assert_response :created
  end

  test "should signup with invitation token and join invited family" do
    inviter = users(:family_admin)
    family = inviter.family
    invitation = family.invitations.create!(
      email: "mobile-invited-new-user@example.com",
      role: "member",
      inviter: inviter
    )

    assert_difference("User.count", 1) do
      assert_no_difference("Family.count") do
        assert_difference("MobileDevice.count", 1) do
          assert_difference("Doorkeeper::AccessToken.count", 1) do
            post "/api/v1/auth/signup", params: {
              user: {
                email: invitation.email,
                password: "SecurePass123!",
                first_name: "Invited",
                last_name: "User"
              },
              device: @device_info,
              invitation_token: invitation.token
            }
          end
        end
      end
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    created_user = User.find(response_data["user"]["id"])
    assert_equal family.id, created_user.family_id
    assert_equal "member", created_user.role
    assert invitation.reload.accepted_at.present?
  end

  test "should reject invitation signup when email does not match token" do
    inviter = users(:family_admin)
    invitation = inviter.family.invitations.create!(
      email: "mobile-invited-only@example.com",
      role: "member",
      inviter: inviter
    )

    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "wrong-mobile-invite@example.com",
          password: "SecurePass123!",
          first_name: "Wrong",
          last_name: "Invite"
        },
        device: @device_info,
        invitation_token: invitation.token
      }
    end

    assert_response :unprocessable_entity
    assert_nil invitation.reload.accepted_at
  end

  test "should reject invalid invite code" do
    # Mock invite code requirement
    Api::V1::AuthController.any_instance.stubs(:invite_code_required?).returns(false)

    assert_no_difference("User.count") do
      post "/api/v1/auth/signup", params: {
        user: {
          email: "newuser@example.com",
          password: "SecurePass123!",
          first_name: "New",
          last_name: "User"
        },
        device: @device_info,
        invite_code: "invalid_code"
      }
    end

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_equal "Invalid invite code", response_data["error"]
  end

  test "should login with invitation token and join invited family" do
    inviter = users(:family_admin)
    target_family = inviter.family
    source_family = Family.create!(
      name: "Existing Mobile Invite Family",
      currency: "USD",
      locale: "en",
      date_format: "%m-%d-%Y"
    )
    invited_user = source_family.users.create!(
      email: "existing-mobile-invite@example.com",
      password: "SecurePass123!",
      password_confirmation: "SecurePass123!"
    )
    invitation = target_family.invitations.create!(
      email: invited_user.email,
      role: "member",
      inviter: inviter
    )

    post "/api/v1/auth/login", params: {
      email: invited_user.email,
      password: "SecurePass123!",
      device: @device_info,
      invitation_token: invitation.token
    }

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal invited_user.id.to_s, response_data.dig("user", "id")
    assert_equal target_family.id, invited_user.reload.family_id
    assert_equal "member", invited_user.role
    assert invitation.reload.accepted_at.present?
  end

  test "should login existing user and return OAuth tokens" do
    user = users(:family_admin)
    password = user_password_test

    # Ensure user has no mobile devices
    user.mobile_devices.destroy_all

    assert_difference("MobileDevice.count", 1) do
      assert_difference("Doorkeeper::AccessToken.count", 1) do
        post "/api/v1/auth/login", params: {
          email: user.email,
          password: password,
          device: @device_info
        }
      end
    end

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal user.id.to_s, response_data["user"]["id"]
    assert_equal user.email, response_data["user"]["email"]
    assert_equal user.ui_layout, response_data["user"]["ui_layout"]
    assert_equal user.ai_enabled?, response_data["user"]["ai_enabled"]

    # OAuth token assertions
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
    assert_equal "Bearer", response_data["token_type"]
    assert_equal 2592000, response_data["expires_in"] # 30 days

    # Verify the device
    device = user.mobile_devices.where(device_id: @device_info[:device_id]).first
    assert device.present?
    assert device.active?
  end

  test "should require MFA when enabled" do
    user = users(:family_admin)
    password = user_password_test

    # Enable MFA for user
    user.setup_mfa!
    user.enable_mfa!

    post "/api/v1/auth/login", params: {
      email: user.email,
      password: password,
      device: @device_info
    }

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Two-factor authentication required", response_data["error"]
    assert response_data["mfa_required"]
  end

  test "should login with valid MFA code" do
    user = users(:family_admin)
    password = user_password_test

    # Enable MFA for user
    user.setup_mfa!
    user.enable_mfa!
    totp = ROTP::TOTP.new(user.otp_secret)

    assert_difference("Doorkeeper::AccessToken.count", 1) do
      post "/api/v1/auth/login", params: {
        email: user.email,
        password: password,
        otp_code: totp.now,
        device: @device_info
      }
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["access_token"].present?
  end

  test "should issue WebAuthn MFA options after valid password" do
    user = users(:family_admin)
    password = user_password_test
    user.setup_mfa!
    user.enable_mfa!
    user.webauthn_credentials.create!(
      credential_id: "credential-id",
      public_key: "public-key",
      sign_count: 0,
      transports: [ "internal" ]
    )

    options = stub(challenge: "webauthn-challenge")
    options.stubs(:as_json).returns({ challenge: "webauthn-challenge", allowCredentials: [ { id: "credential-id" } ] })
    WebAuthn::RelyingParty.any_instance.stubs(:options_for_authentication).returns(options)

    post "/api/v1/auth/webauthn_options", params: {
      email: user.email,
      password: password
    }

    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data["challenge_id"].present?
    assert_equal 300, response_data["expires_in_seconds"]
    assert_equal "webauthn-challenge", response_data.dig("public_key", "challenge")
  end

  test "should login with valid WebAuthn MFA assertion" do
    user = users(:family_admin)
    password = user_password_test
    user.setup_mfa!
    user.enable_mfa!
    credential_record = user.webauthn_credentials.create!(
      credential_id: "credential-id",
      public_key: "public-key",
      sign_count: 1,
      transports: [ "internal" ]
    )
    challenge_id = SecureRandom.uuid
    Rails.cache.write("api:v1:webauthn_authentication:#{user.id}:#{challenge_id}", "webauthn-challenge")

    credential = stub(id: "credential-id", sign_count: 4)
    credential.expects(:verify).with(
      "webauthn-challenge",
      public_key: "public-key",
      sign_count: 1,
      user_presence: true
    )
    WebAuthn::Credential.stubs(:from_get).returns(credential)

    assert_difference("Doorkeeper::AccessToken.count", 1) do
      post "/api/v1/auth/webauthn_verify", params: {
        email: user.email,
        password: password,
        challenge_id: challenge_id,
        credential: webauthn_assertion_payload,
        device: @device_info
      }
    end

    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data["access_token"].present?
    assert_equal user.id.to_s, response_data.dig("user", "id")
    assert_equal 4, credential_record.reload.sign_count
    assert credential_record.last_used_at.present?
    assert_nil Rails.cache.read("api:v1:webauthn_authentication:#{user.id}:#{challenge_id}")
  end

  test "should reject expired WebAuthn MFA challenge" do
    user = users(:family_admin)
    password = user_password_test
    user.setup_mfa!
    user.enable_mfa!
    user.webauthn_credentials.create!(
      credential_id: "credential-id",
      public_key: "public-key",
      sign_count: 0
    )

    post "/api/v1/auth/webauthn_verify", params: {
      email: user.email,
      password: password,
      challenge_id: SecureRandom.uuid,
      credential: webauthn_assertion_payload,
      device: @device_info
    }

    assert_response :unprocessable_entity
    assert_equal "webauthn_challenge_expired", JSON.parse(response.body)["error"]
  end

  test "should reject WebAuthn MFA options with invalid password" do
    user = users(:family_admin)
    user.setup_mfa!
    user.enable_mfa!

    post "/api/v1/auth/webauthn_options", params: {
      email: user.email,
      password: "wrong-password"
    }

    assert_response :unauthorized
    assert_equal "Invalid email or password", JSON.parse(response.body)["error"]
  end

  test "should revoke existing tokens for same device on login" do
    user = users(:family_admin)
    password = user_password_test

    # Create an existing device and token
    device = user.mobile_devices.create!(@device_info)
    existing_token = Doorkeeper::AccessToken.create!(
      application: @shared_app,
      resource_owner_id: user.id,
      mobile_device_id: device.id,
      expires_in: 30.days.to_i,
      scopes: "read_write"
    )

    assert existing_token.accessible?

    post "/api/v1/auth/login", params: {
      email: user.email,
      password: password,
      device: @device_info
    }

    assert_response :success

    # Check that old token was revoked
    existing_token.reload
    assert existing_token.revoked?
  end

  test "should not login with invalid password" do
    user = users(:family_admin)

    assert_no_difference("Doorkeeper::AccessToken.count") do
      post "/api/v1/auth/login", params: {
        email: user.email,
        password: "wrong_password",
        device: @device_info
      }
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Invalid email or password", response_data["error"]
  end

  test "should not login with non-existent email" do
    assert_no_difference("Doorkeeper::AccessToken.count") do
      post "/api/v1/auth/login", params: {
        email: "nonexistent@example.com",
        password: user_password_test,
        device: @device_info
      }
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Invalid email or password", response_data["error"]
  end

  test "request password reset returns generic accepted response and sends email for local user" do
    user = users(:family_admin)

    assert_enqueued_emails 1 do
      post "/api/v1/auth/password_reset", params: { email: user.email }
    end

    assert_response :accepted
    response_data = JSON.parse(response.body)
    assert_equal "If an account exists, password reset instructions will be sent.", response_data["message"]
  end

  test "request password reset does not send email for missing or sso-only users" do
    sso_user = users(:sso_only)

    assert_no_enqueued_emails do
      post "/api/v1/auth/password_reset", params: { email: "missing@example.com" }
      assert_response :accepted

      post "/api/v1/auth/password_reset", params: { email: sso_user.email }
      assert_response :accepted
    end
  end

  test "request password reset rejects when password features are disabled" do
    AuthConfig.stubs(:password_features_enabled?).returns(false)

    post "/api/v1/auth/password_reset", params: { email: users(:family_admin).email }

    assert_response :forbidden
    assert_equal "password_reset_disabled", JSON.parse(response.body)["error"]
  end

  test "reset password updates password with a valid token" do
    user = users(:family_admin)
    token = user.generate_token_for(:password_reset)

    patch "/api/v1/auth/password_reset",
          params: {
            token: token,
            user: {
              password: "new-password",
              password_confirmation: "new-password"
            }
          }

    assert_response :success
    assert_equal "Password has been reset", JSON.parse(response.body)["message"]
    assert user.reload.authenticate("new-password")
  end

  test "reset password rejects invalid token and sso-only users" do
    patch "/api/v1/auth/password_reset",
          params: {
            token: "invalid",
            user: {
              password: "new-password",
              password_confirmation: "new-password"
            }
          }

    assert_response :unprocessable_entity
    assert_equal "invalid_token", JSON.parse(response.body)["error"]

    sso_user = users(:sso_only)
    patch "/api/v1/auth/password_reset",
          params: {
            token: sso_user.generate_token_for(:password_reset),
            user: {
              password: "new-password",
              password_confirmation: "new-password"
            }
          }

    assert_response :unprocessable_entity
    assert_equal "sso_only_user", JSON.parse(response.body)["error"]
    assert_nil sso_user.reload.password_digest
  end

  test "confirm email applies a pending email change" do
    user = users(:new_email)
    user.update!(email: "old-confirm@example.com", unconfirmed_email: "new-confirm@example.com")
    token = user.generate_token_for(:email_confirmation)

    post "/api/v1/auth/email_confirmation", params: { token: token }

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "Email confirmed", response_data["message"]
    assert_equal "new-confirm@example.com", response_data.dig("user", "email")
    assert_equal "new-confirm@example.com", user.reload.email
    assert_nil user.unconfirmed_email
  end

  test "confirm email rejects invalid token" do
    post "/api/v1/auth/email_confirmation", params: { token: "invalid" }

    assert_response :unprocessable_entity
    assert_equal "invalid_token", JSON.parse(response.body)["error"]
  end

  test "resend email confirmation requires auth and pending email change" do
    user = users(:family_admin)
    user.api_keys.active.destroy_all
    api_key = ApiKey.create!(
      user: user,
      name: "Email Confirmation Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "email_confirmation_#{SecureRandom.hex(8)}"
    )
    user.update!(unconfirmed_email: "pending-mobile@example.com")

    assert_enqueued_emails 1 do
      post "/api/v1/auth/email_confirmation/resend", headers: { "X-Api-Key" => api_key.plain_key }
    end

    assert_response :accepted
    assert_equal "Confirmation email sent", JSON.parse(response.body)["message"]

    user.update!(unconfirmed_email: nil)
    post "/api/v1/auth/email_confirmation/resend", headers: { "X-Api-Key" => api_key.plain_key }

    assert_response :unprocessable_entity
    assert_equal "no_pending_email_change", JSON.parse(response.body)["error"]
  end

  test "resend email confirmation requires write scope" do
    user = users(:family_admin)
    user.api_keys.active.destroy_all
    api_key = ApiKey.create!(
      user: user,
      name: "Email Confirmation Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "email_confirmation_read_#{SecureRandom.hex(8)}"
    )

    post "/api/v1/auth/email_confirmation/resend", headers: { "X-Api-Key" => api_key.plain_key }

    assert_response :forbidden
  end

  test "should login even when OAuth application is missing" do
    user = users(:family_admin)
    password = user_password_test

    # Simulate a fresh instance where seeds were never run
    Doorkeeper::Application.where(name: "Sure Mobile").destroy_all
    MobileDevice.instance_variable_set(:@shared_oauth_application, nil)

    assert_difference("Doorkeeper::Application.count", 1) do
      post "/api/v1/auth/login", params: {
        email: user.email,
        password: password,
        device: @device_info
      }
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
  end

  test "should not login without device info" do
    user = users(:family_admin)

    assert_no_difference("Doorkeeper::AccessToken.count") do
      post "/api/v1/auth/login", params: {
        email: user.email,
        password: user_password_test
      }
    end

    assert_response :bad_request
    response_data = JSON.parse(response.body)
    assert_equal "Device information is required", response_data["error"]
  end

  test "should refresh access token with valid refresh token" do
    user = users(:family_admin)
    device = user.mobile_devices.create!(@device_info)

    # Create initial token
    initial_token = Doorkeeper::AccessToken.create!(
      application: @shared_app,
      resource_owner_id: user.id,
      mobile_device_id: device.id,
      expires_in: 30.days.to_i,
      scopes: "read_write",
      use_refresh_token: true
    )

    # Wait to ensure different timestamps
    sleep 0.1

    assert_difference("Doorkeeper::AccessToken.count", 1) do
      post "/api/v1/auth/refresh", params: {
        refresh_token: initial_token.refresh_token,
        device: @device_info
      }
    end

    assert_response :success
    response_data = JSON.parse(response.body)

    # New token assertions
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
    assert_not_equal initial_token.token, response_data["access_token"]
    assert_equal 2592000, response_data["expires_in"]

    # Old token should be revoked
    initial_token.reload
    assert initial_token.revoked?
  end

  test "should not refresh with invalid refresh token" do
    assert_no_difference("Doorkeeper::AccessToken.count") do
      post "/api/v1/auth/refresh", params: {
        refresh_token: "invalid_token",
        device: @device_info
      }
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Invalid refresh token", response_data["error"]
  end

  test "should not refresh without refresh token" do
    post "/api/v1/auth/refresh", params: {
      device: @device_info
    }

    assert_response :bad_request
    response_data = JSON.parse(response.body)
    assert_equal "Refresh token is required", response_data["error"]
  end

  test "should enable ai for authenticated user" do
    user = users(:family_admin)
    user.update!(ai_enabled: false)
    device = user.mobile_devices.create!(@device_info)
    token = Doorkeeper::AccessToken.create!(application: @shared_app, resource_owner_id: user.id, mobile_device_id: device.id, scopes: "read_write")

    patch "/api/v1/auth/enable_ai", headers: {
      "Authorization" => "Bearer #{token.token}",
      "Content-Type" => "application/json"
    }

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal true, response_data.dig("user", "ai_enabled")
    assert_equal user.ui_layout, response_data.dig("user", "ui_layout")
    assert_equal true, user.reload.ai_enabled
  end

  test "should require read_write scope to enable ai" do
    user = users(:family_admin)
    user.update!(ai_enabled: false)
    device = user.mobile_devices.create!(@device_info)
    token = Doorkeeper::AccessToken.create!(application: @shared_app, resource_owner_id: user.id, mobile_device_id: device.id, scopes: "read")

    patch "/api/v1/auth/enable_ai", headers: {
      "Authorization" => "Bearer #{token.token}",
      "Content-Type" => "application/json"
    }

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_data["error"]
    assert_equal "This action requires the 'write' scope", response_data["message"]
    assert_not user.reload.ai_enabled
  end

  test "should require authentication when enabling ai" do
    patch "/api/v1/auth/enable_ai", headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end

  # SSO Link tests
  test "should link existing account via SSO and return tokens" do
    user = users(:family_admin)

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-123",
      email: "google@example.com",
      first_name: "Google",
      last_name: "User",
      name: "Google User",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_difference("OidcIdentity.count", 1) do
      post "/api/v1/auth/sso_link", params: {
        linking_code: linking_code,
        email: user.email,
        password: user_password_test
      }
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
    assert_equal user.id.to_s, response_data["user"]["id"]

    # Linking code should be consumed
    assert_nil Rails.cache.read("mobile_sso_link:#{linking_code}")
  end

  test "should reject SSO link with invalid password" do
    user = users(:family_admin)

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-123",
      email: "google@example.com",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_no_difference("OidcIdentity.count") do
      post "/api/v1/auth/sso_link", params: {
        linking_code: linking_code,
        email: user.email,
        password: "wrong_password"
      }
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Invalid email or password", response_data["error"]

    # Linking code should NOT be consumed on failed password
    assert Rails.cache.read("mobile_sso_link:#{linking_code}").present?, "Expected linking code to survive a failed attempt"
  end

  test "should reject SSO link when user has MFA enabled" do
    user = users(:family_admin)
    user.update!(otp_required: true, otp_secret: ROTP::Base32.random(32))

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-mfa",
      email: "mfa@example.com",
      first_name: "MFA",
      last_name: "User",
      name: "MFA User",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_no_difference("OidcIdentity.count") do
      post "/api/v1/auth/sso_link", params: {
        linking_code: linking_code,
        email: user.email,
        password: user_password_test
      }
    end

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal true, response_data["mfa_required"]
    assert_match(/MFA/, response_data["error"])

    # Linking code should NOT be consumed on MFA rejection
    assert Rails.cache.read("mobile_sso_link:#{linking_code}").present?, "Expected linking code to survive MFA rejection"
  end

  test "should reject SSO link with expired linking code" do
    post "/api/v1/auth/sso_link", params: {
      linking_code: "expired-code",
      email: "test@example.com",
      password: "password"
    }

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Linking code is invalid or expired", response_data["error"]
  end

  test "should reject SSO link without linking code" do
    post "/api/v1/auth/sso_link", params: {
      email: "test@example.com",
      password: "password"
    }

    assert_response :bad_request
    response_data = JSON.parse(response.body)
    assert_equal "Linking code is required", response_data["error"]
  end

  test "linking_code is single-use under race" do
    user = users(:family_admin)

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-race-test",
      email: "race@example.com",
      first_name: "Race",
      last_name: "Test",
      name: "Race Test",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    # First request succeeds
    assert_difference("OidcIdentity.count", 1) do
      post "/api/v1/auth/sso_link", params: {
        linking_code: linking_code,
        email: user.email,
        password: user_password_test
      }
    end
    assert_response :success

    # Second request with the same code is rejected
    assert_no_difference("OidcIdentity.count") do
      post "/api/v1/auth/sso_link", params: {
        linking_code: linking_code,
        email: user.email,
        password: user_password_test
      }
    end
    assert_response :unauthorized
    assert_equal "Linking code is invalid or expired", JSON.parse(response.body)["error"]
    assert_nil Rails.cache.read("mobile_sso_link:#{linking_code}")
  end

  # SSO Create Account tests
  test "should create new account via SSO and return tokens" do
    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-456",
      email: "newgoogleuser@example.com",
      first_name: "New",
      last_name: "GoogleUser",
      name: "New GoogleUser",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_difference([ "User.count", "OidcIdentity.count" ], 1) do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "New",
        last_name: "GoogleUser"
      }
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data["access_token"].present?
    assert response_data["refresh_token"].present?
    assert_equal "newgoogleuser@example.com", response_data["user"]["email"]
    assert_equal "New", response_data["user"]["first_name"]
    assert_equal "GoogleUser", response_data["user"]["last_name"]

    # Linking code should be consumed
    assert_nil Rails.cache.read("mobile_sso_link:#{linking_code}")
  end

  test "should reject SSO create account when not allowed" do
    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-789",
      email: "blocked@example.com",
      first_name: "Blocked",
      last_name: "User",
      device_info: @device_info.stringify_keys,
      allow_account_creation: false
    }, expires_in: 10.minutes)

    assert_no_difference("User.count") do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "Blocked",
        last_name: "User"
      }
    end

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_match(/disabled/, response_data["error"])

    # Linking code should NOT be consumed on rejection
    assert Rails.cache.read("mobile_sso_link:#{linking_code}").present?, "Expected linking code to survive a rejected create account attempt"
  end

  test "should reject SSO create account with expired linking code" do
    post "/api/v1/auth/sso_create_account", params: {
      linking_code: "expired-code",
      first_name: "Test",
      last_name: "User"
    }

    assert_response :unauthorized
    response_data = JSON.parse(response.body)
    assert_equal "Linking code is invalid or expired", response_data["error"]
  end

  test "should reject SSO create account without linking code" do
    post "/api/v1/auth/sso_create_account", params: {
      first_name: "Test",
      last_name: "User"
    }

    assert_response :bad_request
    response_data = JSON.parse(response.body)
    assert_equal "Linking code is required", response_data["error"]
  end

  test "should return 422 when SSO create account fails user validation" do
    existing_user = users(:family_admin)

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-dup-email",
      email: existing_user.email,
      first_name: "Duplicate",
      last_name: "Email",
      name: "Duplicate Email",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_no_difference([ "User.count", "OidcIdentity.count" ]) do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "Duplicate",
        last_name: "Email"
      }
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert response_data["errors"].any? { |e| e.match?(/email/i) }, "Expected email validation error in: #{response_data["errors"]}"
  end

  test "sso_create_account rolls back user when OIDC identity creation fails" do
    email = "mobile-rollback@example.com"
    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-rollback",
      email: email,
      first_name: "Mobile",
      last_name: "Rollback",
      name: "Mobile Rollback",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)
    OidcIdentity.stubs(:create_from_omniauth).raises(ActiveRecord::RecordNotUnique, "duplicate identity")

    assert_no_difference([ "User.count", "OidcIdentity.count", "Family.count" ]) do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "Mobile",
        last_name: "Rollback"
      }
    end

    assert_response :unprocessable_entity
    assert_nil User.find_by(email: email)
  end

  test "sso_create_account linking_code single-use under race" do
    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "google_oauth2",
      uid: "google-uid-race-create",
      email: "raceuser@example.com",
      first_name: "Race",
      last_name: "CreateUser",
      name: "Race CreateUser",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    # First request succeeds
    assert_difference([ "User.count", "OidcIdentity.count" ], 1) do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "Race",
        last_name: "CreateUser"
      }
    end
    assert_response :success

    # Second request with the same code is rejected
    assert_no_difference([ "User.count", "OidcIdentity.count" ]) do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "Race",
        last_name: "CreateUser"
      }
    end
    assert_response :unauthorized
    assert_equal "Linking code is invalid or expired", JSON.parse(response.body)["error"]
    assert_nil Rails.cache.read("mobile_sso_link:#{linking_code}")
  end

  test "should return forbidden when ai is not available" do
    user = users(:family_admin)
    user.update!(ai_enabled: false)
    device = user.mobile_devices.create!(@device_info)
    token = Doorkeeper::AccessToken.create!(application: @shared_app, resource_owner_id: user.id, mobile_device_id: device.id, scopes: "read_write")
    User.any_instance.stubs(:ai_available?).returns(false)

    patch "/api/v1/auth/enable_ai", headers: {
      "Authorization" => "Bearer #{token.token}",
      "Content-Type" => "application/json"
    }

    assert_response :forbidden
    response_data = JSON.parse(response.body)
    assert_equal "AI is not available for your account", response_data["error"]
    assert_not user.reload.ai_enabled
  end

  test "mobile SSO onboarding via invitation shares existing family accounts when family shares by default" do
    family = families(:dylan_family)
    family.update!(default_account_sharing: "shared")
    invitation = family.invitations.create!(
      email: "mobile-invitee@example.com", role: "member", inviter: users(:family_admin)
    )

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "openid_connect",
      uid: "mobile-invite-uid-1",
      email: invitation.email,
      first_name: "Mobile",
      last_name: "Invitee",
      name: "Mobile Invitee",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    assert_difference("User.count", 1) do
      post "/api/v1/auth/sso_create_account", params: {
        linking_code: linking_code,
        first_name: "Mobile",
        last_name: "Invitee"
      }
    end

    assert_response :success
    invitee = User.find_by(email: invitation.email)
    assert_not_nil invitee
    assert_equal family.id, invitee.family_id
    assert_equal family.accounts.pluck(:id).sort,
      AccountShare.where(user: invitee).pluck(:account_id).sort
  end

  test "mobile SSO onboarding via invitation shares nothing when family sharing is private" do
    family = families(:dylan_family)
    family.update!(default_account_sharing: "private")
    invitation = family.invitations.create!(
      email: "mobile-private@example.com", role: "member", inviter: users(:family_admin)
    )

    linking_code = SecureRandom.urlsafe_base64(32)
    Rails.cache.write("mobile_sso_link:#{linking_code}", {
      provider: "openid_connect",
      uid: "mobile-private-uid-1",
      email: invitation.email,
      first_name: "Mobile",
      last_name: "Private",
      name: "Mobile Private",
      device_info: @device_info.stringify_keys,
      allow_account_creation: true
    }, expires_in: 10.minutes)

    post "/api/v1/auth/sso_create_account", params: {
      linking_code: linking_code,
      first_name: "Mobile",
      last_name: "Private"
    }

    assert_response :success
    invitee = User.find_by(email: invitation.email)
    assert_not_nil invitee
    assert_equal family.id, invitee.family_id
    assert_equal 0, AccountShare.where(user: invitee).count
  end

  private

    def webauthn_assertion_payload
      {
        id: "credential-id",
        rawId: "credential-id",
        type: "public-key",
        response: {
          authenticatorData: "authenticator-data",
          clientDataJSON: "client-data-json",
          signature: "signature",
          userHandle: nil
        }
      }
    end
end
