module Killbill #:nodoc:
  module Stripe #:nodoc:
    class StripePaymentMethod < ::Killbill::Plugin::ActiveMerchant::ActiveRecord::PaymentMethod

      self.table_name = 'stripe_payment_methods'

      def self.from_response(kb_account_id, kb_payment_method_id, kb_tenant_id, cc_or_token, response, options, extra_params = {}, model = ::Killbill::Stripe::StripePaymentMethod)
        stripe_customer_id = self.stripe_customer_id_from_kb_account_id(kb_account_id, kb_tenant_id)
        if !stripe_customer_id.blank? && response.respond_to?(:responses)
          card_response     = response.responses.first.params
          customer_response = response.responses.last.params
        elsif response.params['sources']
          card_response     = response.params['sources']['data'][0]
          customer_response = response.params
        else
          card_response = {}
          customer_response = {}
        end

        # See Response#from_response
        current_time = Time.now.utc
        model.new({
                      #:kb_account_id        => kb_account_id,
                      :kb_payment_method_id => kb_payment_method_id,
                      #:kb_tenant_id         => kb_tenant_id,
                      :token                => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? response.authorization : (cc_or_token || response.authorization),
                      :cc_first_name        => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.first_name : extra_params[:cc_first_name],
                      :cc_last_name         => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.last_name : extra_params[:cc_last_name],
                      :cc_type              => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.brand : extra_params[:cc_type],
                      :cc_exp_month         => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.month : extra_params[:cc_exp_month],
                      :cc_exp_year          => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.year : extra_params[:cc_exp_year],
                      :cc_last_4            => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.last_digits : extra_params[:cc_last_4],
                      :cc_number            => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.number : nil,
                      :address1             => (options[:billing_address] || {})[:address1],
                      :address2             => (options[:billing_address] || {})[:address2],
                      :city                 => (options[:billing_address] || {})[:city],
                      :state                => (options[:billing_address] || {})[:state],
                      :zip                  => (options[:billing_address] || {})[:zip],
                      :country              => (options[:billing_address] || {})[:country],
                      :created_at           => current_time,
                      :updated_at           => current_time
                  }.merge!(extra_params.compact)) # Don't override with nil values

             self.from_response_super(kb_account_id,
              kb_payment_method_id,
              kb_tenant_id,
              cc_or_token,
              response,
              options,
              {
                  :stripe_customer_id => customer_response['id'],
                  :token              => card_response['id'],
                  :cc_first_name      => card_response['name'],
                  :cc_last_name       => nil,
                  :cc_type            => card_response['brand'],
                  :cc_exp_month       => card_response['exp_month'],
                  :cc_exp_year        => card_response['exp_year'],
                  :cc_last_4          => card_response['last4'],
                  :address1           => card_response['address_line1'],
                  :address2           => card_response['address_line2'],
                  :city               => card_response['address_city'],
                  :state              => card_response['address_state'],
                  :zip                => card_response['address_zip'],
                  :country            => card_response['address_country']
              }.merge!(extra_params),
              model)
      end

      def self.from_response_super(kb_account_id, kb_payment_method_id, kb_tenant_id, cc_or_token, response, options, extra_params = {}, model = PaymentMethod)
        # See Response#from_response
        current_time = Time.now.utc
        model.new({
                      #:kb_account_id        => kb_account_id,
                      :kb_payment_method_id => kb_payment_method_id,
                     # :kb_tenant_id         => kb_tenant_id,
                      :token                => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? response.authorization : (cc_or_token || response.authorization),
                      :cc_first_name        => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.first_name : extra_params[:cc_first_name],
                      :cc_last_name         => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.last_name : extra_params[:cc_last_name],
                      :cc_type              => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.brand : extra_params[:cc_type],
                      :cc_exp_month         => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.month : extra_params[:cc_exp_month],
                      :cc_exp_year          => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.year : extra_params[:cc_exp_year],
                      :cc_last_4            => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.last_digits : extra_params[:cc_last_4],
                      :cc_number            => cc_or_token.kind_of?(::ActiveMerchant::Billing::CreditCard) ? cc_or_token.number : nil,
                      :address1             => (options[:billing_address] || {})[:address1],
                      :address2             => (options[:billing_address] || {})[:address2],
                      :city                 => (options[:billing_address] || {})[:city],
                      :state                => (options[:billing_address] || {})[:state],
                      :zip                  => (options[:billing_address] || {})[:zip],
                      :country              => (options[:billing_address] || {})[:country],
                      :created_at           => current_time,
                      :updated_at           => current_time
                  }.merge!(extra_params.compact)) # Don't override with nil values
      end

      def self.search_where_clause(t, search_key)
        super.or(t[:stripe_customer_id].eq(search_key))
      end

      def self.stripe_customer_id_from_kb_account_id(kb_account_id, tenant_id)

        #query account on account & tenant? account_id maps to payment_methods. payment method external_key
        kb_pm = KbPaymentMethod.where(account_id: kb_account_id)

        pms ||= Array.new

        kb_pm.each { |payment_method|
          match = StripePaymentMethod.where(kb_payment_method_id: payment_method.external_key).first
          pms.push(match)
        }

        # many
        return nil if pms.empty?

        stripe_customer_ids = Set.new
        pms.each { |pm| stripe_customer_ids << pm.stripe_customer_id }
        raise "No Stripe customer id found for account #{kb_account_id}" if stripe_customer_ids.empty?
        raise "Kill Bill account #{kb_account_id} mapping to multiple Stripe customers: #{stripe_customer_ids.to_a}" if stripe_customer_ids.size > 1
        stripe_customer_ids.first
      end

      def self.mark_as_deleted!(kb_payment_method_id, kb_tenant_id)
        payment_method = from_kb_payment_method_id(kb_payment_method_id, kb_tenant_id)
        payment_method.is_deleted = true
        payment_method.save!(shared_activerecord_options)
      end

      def self.from_kb_payment_method_id(kb_payment_method_id, kb_tenant_id)

        # we want to find the payment method record that maps to the correct stripe pm.
        # we need to look at the killbill payment table and grab the external_key.
        kb_pm = KbPaymentMethod.where(id: kb_payment_method_id).first

        payment_methods = where("kb_payment_method_id = #{@@quotes_cache[kb_pm.external_key]} AND is_deleted = #{@@quotes_cache[false]}")

        raise "No payment method found for payment method #{kb_payment_method_id} and tenant #{kb_tenant_id}" if payment_methods.empty?
        raise "Kill Bill payment method #{kb_payment_method_id} mapping to multiple active plugin payment methods" if payment_methods.size > 1
        payment_methods[0]
      end
    end
  end
end
