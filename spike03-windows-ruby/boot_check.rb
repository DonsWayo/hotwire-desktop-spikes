# Boots the generated app and serves one request, so "it boots" means the
# stack actually answered rather than merely loaded.
require "./config/environment"
require "rack/mock"

Rails.application.routes.draw do
  get "/up", to: proc { [200, { "content-type" => "text/plain" }, ["ok"]] }
end

status, = Rails.application.call(Rack::MockRequest.env_for("http://127.0.0.1/up"))
abort "GET /up returned #{status}" unless status == 200

puts "OK  Rails #{Rails::VERSION::STRING} booted and served a request"
puts "    ruby    #{RUBY_VERSION} #{RUBY_PLATFORM} at #{RbConfig::CONFIG['prefix']}"
puts "    psych   #{Psych::VERSION} (libyaml #{Psych::LIBYAML_VERSION})"
puts "    openssl #{OpenSSL::OPENSSL_VERSION}"
