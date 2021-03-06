# -- encoding : utf-8 --

set :views, File.expand_path(File.dirname(__FILE__) + '/views')

include Killbill::Plugin::ActiveMerchant::Sinatra

configure do
  # Usage: rackup -Ilib -E test
  if development? or test?
    # Make sure the plugin is initialized
    plugin              = ::Killbill::Stripe::PaymentPlugin.new
    plugin.logger       = Logger.new(STDOUT)
    plugin.logger.level = Logger::INFO
    plugin.conf_dir     = File.dirname(File.dirname(__FILE__)) + '/..'
    plugin.start_plugin
  end
end

helpers do
  def plugin(session = {})
    ::Killbill::Stripe::PrivatePaymentPlugin.new(session)
  end
end

# http://127.0.0.1:9292/plugins/killbill-stripe
get '/plugins/killbill-stripe' do
  kb_account_id = request.GET['kb_account_id']
  required_parameter! :kb_account_id, kb_account_id

  kb_tenant_id = request.GET['kb_tenant_id']
  kb_tenant = request.env['killbill_tenant']
  kb_tenant_id ||= kb_tenant.id.to_s unless kb_tenant.nil?

  # URL to Stripe.js
  stripejs_url = config(kb_tenant_id)[:stripe][:stripejs_url] || 'https://js.stripe.com/v2/'
  required_parameter! :stripejs_url, stripejs_url, 'is not configured'

  # Public API key
  publishable_key = config(kb_tenant_id)[:stripe][:api_publishable_key]
  required_parameter! :publishable_key, publishable_key, 'is not configured'

  # Skip redirect? Useful for testing the flow with Kill Bill
  no_redirect = request.GET['no_redirect'] == '1'

  locals = {
      :stripejs_url    => stripejs_url,
      :publishable_key => publishable_key,
      :kb_account_id   => kb_account_id,
      :kb_tenant_id    => kb_tenant_id,
      :no_redirect     => no_redirect
  }
  erb :stripejs, :locals => locals
end

# This is mainly for testing. Your application should redirect from the Stripe.js checkout above
# to a custom endpoint where you call the Kill Bill add payment method JAX-RS API.
post '/plugins/killbill-stripe', :provides => 'json' do
  params.to_json
end

# curl -v http://127.0.0.1:9292/plugins/killbill-stripe/1.0/pms/1
get '/plugins/killbill-stripe/1.0/pms/:id', :provides => 'json' do
  if pm = ::Killbill::Stripe::StripePaymentMethod.find_by_id(params[:id].to_i)
    pm.to_json
  else
    status 404
  end
end

# curl -v http://127.0.0.1:9292/plugins/killbill-stripe/1.0/transactions/1
get '/plugins/killbill-stripe/1.0/transactions/:id', :provides => 'json' do
  if transaction = ::Killbill::Stripe::StripeTransaction.find_by_id(params[:id].to_i)
    transaction.to_json
  else
    status 404
  end
end

# curl -v http://127.0.0.1:9292/plugins/killbill-stripe/1.0/responses/1
get '/plugins/killbill-stripe/1.0/responses/:id', :provides => 'json' do
  if transaction = ::Killbill::Stripe::StripeResponse.find_by_id(params[:id].to_i)
    transaction.to_json
  else
    status 404
  end
end
