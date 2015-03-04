require 'spec_helper'

ActiveMerchant::Billing::Base.mode = :test

describe Killbill::Stripe::PaymentPlugin do

  include ::Killbill::Plugin::ActiveMerchant::RSpec

  before(:each) do
    @plugin = Killbill::Stripe::PaymentPlugin.new

    @call_context           = Killbill::Plugin::Model::CallContext.new
    @call_context.tenant_id = '00001011-a022-b033-0055-aa0000000066'
    @call_context           = @call_context.to_ruby(@call_context)



    @account_api    = ::Killbill::Plugin::ActiveMerchant::RSpec::FakeJavaUserAccountApi.new
    @payment_api    = ::Killbill::Plugin::ActiveMerchant::RSpec::FakeJavaPaymentApi.new
    @tenant_api     = ::Killbill::Plugin::ActiveMerchant::RSpec::FakeJavaTenantUserApi.new({@call_context.tenant_id => get_tenant_config})

    svcs            = {:account_user_api => @account_api, :payment_api => @payment_api, :tenant_user_api => @tenant_api}
    @plugin.kb_apis = Killbill::Plugin::KillbillApi.new('stripe', svcs)


    @plugin.logger       = Logger.new(STDOUT)
    @plugin.logger.level = Logger::INFO
    @plugin.conf_dir     = File.expand_path(File.dirname(__FILE__) + '../../../../')
    @plugin.start_plugin

    @properties = []
    @pm         = create_payment_method(::Killbill::Stripe::StripePaymentMethod, nil, @call_context.tenant_id, @properties)
    @amount     = BigDecimal.new('100')
    @currency   = 'USD'

    kb_payment_id = SecureRandom.uuid
    1.upto(6) do
      @kb_payment = @payment_api.add_payment(kb_payment_id)
    end
  end


  def get_tenant_config
    config_dir = File.dirname(File.dirname(__FILE__)) + '/../..'
    per_tenant_config_name = "#{config_dir}/stripe.yml"
    per_tenant_config = File.open(per_tenant_config_name, 'rb') { |file| file.read }
    per_tenant_config
  end

  after(:each) do
    @plugin.stop_plugin
  end

  it 'should be able to create and retrieve payment methods with per tenant config' do
    pm = create_payment_method(::Killbill::Stripe::StripePaymentMethod, nil, @call_context.tenant_id)

    pms = @plugin.get_payment_methods(pm.kb_account_id, false, [], @call_context)
    pms.size.should == 1
    pms.first.external_payment_method_id.should == pm.token

    pm_details = @plugin.get_payment_method_detail(pm.kb_account_id, pm.kb_payment_method_id, [], @call_context)
    pm_details.external_payment_method_id.should == pm.token

    pms_found = @plugin.search_payment_methods pm.cc_last_4, 0, 10, [], @call_context
    pms_found = pms_found.iterator.to_a
    pms_found.size.should == 2
    pms_found[1].external_payment_method_id.should == pm_details.external_payment_method_id

    @plugin.delete_payment_method(pm.kb_account_id, pm.kb_payment_method_id, [], @call_context)

    @plugin.get_payment_methods(pm.kb_account_id, false, [], @call_context).size.should == 0
    lambda { @plugin.get_payment_method_detail(pm.kb_account_id, pm.kb_payment_method_id, [], @call_context) }.should raise_error RuntimeError

    # Verify we can add multiple payment methods
    pm1 = create_payment_method(::Killbill::Stripe::StripePaymentMethod, pm.kb_account_id, @call_context.tenant_id)
    pm2 = create_payment_method(::Killbill::Stripe::StripePaymentMethod, pm.kb_account_id, @call_context.tenant_id)

    pms = @plugin.get_payment_methods(pm.kb_account_id, false, [], @call_context)
    pms.size.should == 2
    pms[0].external_payment_method_id.should == pm1.token
    pms[1].external_payment_method_id.should == pm2.token

    # Update the default payment method in Stripe (we cannot easily verify the result unfortunately)
    @plugin.set_default_payment_method(pm.kb_account_id, pm2.kb_payment_method_id, [], @call_context)
    response = Killbill::Stripe::StripeResponse.last
    response.api_call.should == 'set_default_payment_method'
    response.message.should == 'Transaction approved'
    response.success.should be_true
  end

end
