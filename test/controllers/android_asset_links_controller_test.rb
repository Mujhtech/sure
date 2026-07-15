require "test_helper"

class AndroidAssetLinksControllerTest < ActionDispatch::IntegrationTest
  test "returns an empty statement list when Android signing certificates are not configured" do
    with_env_overrides("ANDROID_APP_SHA256_CERT_FINGERPRINTS" => nil) do
      get "/.well-known/assetlinks.json"

      assert_response :ok
      assert_equal "application/json", response.content_type.split(";").first
      assert_equal [], response.parsed_body
    end
  end

  test "returns the passkey credential delegation statement" do
    first_fingerprint = Array.new(32, "A1").join(":")
    second_fingerprint = "b2" * 32

    with_env_overrides(
      "ANDROID_APP_PACKAGE_NAME" => "com.example.northledger",
      "ANDROID_APP_SHA256_CERT_FINGERPRINTS" => "#{first_fingerprint},\n#{second_fingerprint}"
    ) do
      get "/.well-known/assetlinks.json"

      assert_response :ok
      statement = response.parsed_body.fetch(0)
      assert_equal [ "delegate_permission/common.get_login_creds" ], statement.fetch("relation")
      assert_equal "android_app", statement.dig("target", "namespace")
      assert_equal "com.example.northledger", statement.dig("target", "package_name")
      assert_equal [
        first_fingerprint,
        Array.new(32, "B2").join(":")
      ], statement.dig("target", "sha256_cert_fingerprints")
      assert_match(/public/, response.headers.fetch("cache-control"))
    end
  end

  test "ignores invalid and duplicate signing certificate fingerprints" do
    fingerprint = Array.new(32, "C3").join(":")

    with_env_overrides(
      "ANDROID_APP_SHA256_CERT_FINGERPRINTS" => "invalid,#{fingerprint},#{fingerprint.downcase}"
    ) do
      get "/.well-known/assetlinks.json"

      assert_response :ok
      assert_equal [ fingerprint ], response.parsed_body.dig(0, "target", "sha256_cert_fingerprints")
    end
  end
end
