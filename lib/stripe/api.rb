include Killbill::Plugin::ActiveMerchant
module Killbill #:nodoc:
  module Stripe #:nodoc:
    class PaymentPlugin < ::Killbill::Plugin::ActiveMerchant::PaymentPlugin


      def initialize
        gateway_builder = Proc.new do |config|
          ::ActiveMerchant::Billing::StripeGateway.new :login => config[:api_secret_key]
        end


        super(gateway_builder,
              :stripe,
              ::Killbill::Stripe::StripePaymentMethod,
              ::Killbill::Stripe::StripeTransaction,
              ::Killbill::Stripe::StripeResponse)



      end

      def on_event(event)
        # Require to deal with per tenant configuration invalidation
        super(event)
        #
        # Custom event logic could be added below...
        #
      end

      def authorize_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context)

        pm = @payment_method_model.from_kb_payment_method_id(kb_payment_method_id, context.tenant_id)

        options = {
            :customer => pm.stripe_customer_id,
            :destination => get_destination(context.tenant_id),
            :application_fee => get_application_fee(amount)
        }

        properties = merge_properties(properties, options)

        gateway_call_proc = Proc.new do |gateway, linked_transaction, payment_source, amount_in_cents, options|
          gateway.authorize(amount_in_cents, payment_source, options)
        end

        dispatch_to_gateways(:authorize, kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context, gateway_call_proc)
      end

      def capture_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        gateway_call_proc = Proc.new do |gateway, linked_transaction, payment_source, amount_in_cents, options|
          gateway.capture(amount_in_cents, linked_transaction.txn_id, options)
        end

        linked_transaction_proc = Proc.new do |amount_in_cents, options|
          # TODO We use the last transaction at the moment, is it good enough?
          last_authorization = @transaction_model.authorizations_from_kb_payment_id(kb_payment_id, context.tenant_id).last
          raise "Unable to retrieve last authorization for operation=capture, kb_payment_id=#{kb_payment_id}, kb_payment_transaction_id=#{kb_payment_transaction_id}, kb_payment_method_id=#{kb_payment_method_id}" if last_authorization.nil?
          last_authorization
        end

        dispatch_to_gateways(:capture, kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context, gateway_call_proc, linked_transaction_proc)

      end

      def purchase_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context)
        pm = @payment_method_model.from_kb_payment_method_id(kb_payment_method_id, context.tenant_id)

        # Pass extra parameters for the gateway here
        options = {
            :customer => pm.stripe_customer_id,
            :destination => get_destination(context.tenant_id),
            :application_fee => get_application_fee(amount)
        }

        properties = merge_properties(properties, options)
        gateway_call_proc = Proc.new do |gateway, linked_transaction, payment_source, amount_in_cents, options|
          gateway.purchase(amount_in_cents, payment_source, options)
        end

        dispatch_to_gateways(:purchase, kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context, gateway_call_proc)
      end

      def void_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        gateway_call_proc = Proc.new do |gateway, linked_transaction, payment_source, amount_in_cents, options|
          authorization = linked_transaction.txn_id

          # Go to the gateway - while some gateways implementations are smart and have void support 'auth_reversal' and 'void' (e.g. Litle),
          # others (e.g. CyberSource) implement different methods
          linked_transaction.transaction_type == 'AUTHORIZE' && gateway.respond_to?(:auth_reversal) ? gateway.auth_reversal(linked_transaction.amount_in_cents, authorization, options) : gateway.void(authorization, options)
        end

        linked_transaction_proc = Proc.new do |amount_in_cents, options|
          linked_transaction_type = find_value_from_properties(properties, :linked_transaction_type)
          if linked_transaction_type.nil?
            # Default behavior to search for the last transaction
            # If an authorization is being voided, we're performing an 'auth_reversal', otherwise,
            # we're voiding an unsettled capture or purchase (which often needs to happen within 24 hours).
            last_transaction = @transaction_model.purchases_from_kb_payment_id(kb_payment_id, context.tenant_id).last
            if last_transaction.nil?
              last_transaction = @transaction_model.captures_from_kb_payment_id(kb_payment_id, context.tenant_id).last
              if last_transaction.nil?
                last_transaction = @transaction_model.authorizations_from_kb_payment_id(kb_payment_id, context.tenant_id).last
                if last_transaction.nil?
                  raise ArgumentError.new("Kill Bill payment #{kb_payment_id} has no auth, capture or purchase, thus cannot be voided")
                end
              end
            end
          else
            last_transaction = @transaction_model.send("#{linked_transaction_type.to_s}s_from_kb_payment_id", kb_payment_id, context.tenant_id).last
          end
          last_transaction
        end

        dispatch_to_gateways(:void, kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, nil, nil, properties, context, gateway_call_proc, linked_transaction_proc)

      end

      def refund_payment(kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context)
        # Pass extra parameters for the gateway here
        options = {
            :reverse_transfer => true,
            :refund_application_fee => true
        }

        properties = merge_properties(properties, options)
        gateway_call_proc = Proc.new do |gateway, linked_transaction, payment_source, amount_in_cents, options|
          gateway.refund(amount_in_cents, linked_transaction.txn_id, options)
        end

        linked_transaction_proc = Proc.new do |amount_in_cents, options|
          linked_transaction_type = find_value_from_properties(properties, :linked_transaction_type)
          transaction             = @transaction_model.find_candidate_transaction_for_refund(kb_payment_id, context.tenant_id, amount_in_cents, linked_transaction_type)
          raise "Unable to retrieve transaction to refund for operation=refund, kb_payment_id=#{kb_payment_id}, kb_payment_transaction_id=#{kb_payment_transaction_id}, kb_payment_method_id=#{kb_payment_method_id}" if transaction.nil?
          transaction
        end

        dispatch_to_gateways(:refund, kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context, gateway_call_proc, linked_transaction_proc)
      end

      def get_payment_info(kb_account_id, kb_payment_id, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        super(kb_account_id, kb_payment_id, properties, context)
      end

      def search_payments(search_key, offset, limit, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        super(search_key, offset, limit, properties, context)
      end

      def add_payment_method(kb_account_id, kb_payment_method_id, payment_method_props, set_default, properties, context)
        # Do we have a customer for that account already?

        stripe_customer_id = StripePaymentMethod.stripe_customer_id_from_kb_account_id(kb_account_id, context.tenant_id)

        # Pass extra parameters for the gateway here
        options = {
            :email => @kb_apis.account_user_api.get_account_by_id(kb_account_id, @kb_apis.create_context(context.tenant_id)).email,
            # This will either update the current customer if present, or create a new one
            :customer => stripe_customer_id,
            # Magic field, see also private_api.rb (works only when creating an account)
            :description => kb_account_id
        }

        properties = merge_properties(properties, options)
        all_properties        = (payment_method_props.nil? || payment_method_props.properties.nil? ? [] : payment_method_props.properties) + properties
        options               = properties_to_hash(properties)
        options[:set_default] ||= set_default
        options[:order_id]    ||= kb_payment_method_id

        should_skip_gw = Utils.normalized(options, :skip_gw)

        # Registering a card or a token
        if should_skip_gw
          # If nothing is passed, that's fine -  we probably just want a placeholder row in the plugin
          payment_source = get_payment_source(nil, all_properties, options, context) rescue nil
        else
          payment_source = get_payment_source(nil, all_properties, options, context)
        end

        # Go to the gateway
        payment_processor_account_id = Utils.normalized(options, :payment_processor_account_id) || :default
        gateway                      = lookup_gateway(payment_processor_account_id, context.tenant_id)
        gw_response                  = gateway.store(payment_source, options)
        response, transaction        = save_response_and_transaction(gw_response, :add_payment_method, kb_account_id, context.tenant_id, payment_processor_account_id)

        if response.success
          # If we have skipped the call to the gateway, we still need to store the payment method (either a token or the full credit card)
          if should_skip_gw
            cc_or_token = payment_source
          else
            # response.authorization may be a String combination separated by ; - don't split it! Some plugins expect it as-is (they split it themselves)
            cc_or_token = response.authorization
          end

          attributes = properties_to_hash(all_properties)
          # Note: keep the same keys as in build_am_credit_card below
          extra_params = {
              :cc_first_name => Utils.normalized(attributes, :cc_first_name),
              :cc_last_name => Utils.normalized(attributes, :cc_last_name),
              :cc_type => Utils.normalized(attributes, :cc_type),
              :cc_exp_month => Utils.normalized(attributes, :cc_expiration_month),
              :cc_exp_year => Utils.normalized(attributes, :cc_expiration_year),
              :cc_last_4 => Utils.normalized(attributes, :cc_last_4)
          }
          payment_method = @payment_method_model.from_response(kb_account_id, kb_payment_method_id, context.tenant_id, cc_or_token, gw_response, options, extra_params, @payment_method_model)
          payment_method.save!
          payment_method
        else
          raise response.message
        end

        # we need to update all the other payments related to our external key.
        # in our implementation, we have accounts that are in different tenants
        # we want to keep them all pointing to the same stripe account
        ext_key = @kb_apis.account_user_api.get_account_by_id(kb_account_id, @kb_apis.create_context(context.tenant_id)).external_key
        accounts = Accounts.where(external_key: ext_key).where.not(id: kb_account_id)
        accounts.each { |account|
          random_id = SecureRandom.uuid
          pm = KbPaymentMethod.new
          pm.external_key = kb_payment_method_id
          pm.id = random_id
          pm.account_id = account.id
          pm.plugin_name = 'killbill-stripe'
          pm.is_active = true
          pm.created_by = 'admin'
          pm.updated_by = 'admin'
          pm.updated_date = Time.now.utc
          pm.created_date = Time.now.utc
          pm.account_record_id = account.record_id
          pm.tenant_record_id = account.tenant_record_id
          pm.save!

          if set_default
            account.payment_method_id = random_id
            account.save!
          end
        }
      end

      def delete_payment_method(kb_account_id, kb_payment_method_id, properties, context)
        pm = StripePaymentMethod.from_kb_payment_method_id(kb_payment_method_id, context.tenant_id)

        # Pass extra parameters for the gateway here
        options = {
            :customer_id => pm.stripe_customer_id
        }

        properties = merge_properties(properties, options)

        options = properties_to_hash(properties)

        # Delete the card
        payment_processor_account_id = Utils.normalized(options, :payment_processor_account_id) || :default
        gateway                      = lookup_gateway(payment_processor_account_id, context.tenant_id)

        customer_id = Utils.normalized(options, :customer_id)
        if customer_id
          gw_response = gateway.unstore(customer_id, pm.token, options)
        else
          gw_response = gateway.unstore(pm.token, options)
        end
        response, transaction = save_response_and_transaction(gw_response, :delete_payment_method, kb_account_id, context.tenant_id, payment_processor_account_id)

        if response.success
          # since we share cc between tenants, we need to find the other tenants that have this card and make them as deactivated
          kb_pm = KbPaymentMethod.where(external_key: pm.kb_payment_method_id).where.not(id: kb_payment_method_id)
          kb_pm.each { |payment_method|
            payment_method.is_active = 0
            payment_method.save!
          }
          @payment_method_model.mark_as_deleted! kb_payment_method_id, context.tenant_id
        else
          raise response.message
        end

      end

      def get_payment_method_detail(kb_account_id, kb_payment_method_id, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        options = properties_to_hash(properties)
        @payment_method_model.from_kb_payment_method_id(kb_payment_method_id, context.tenant_id).to_payment_method_plugin
      end

      def set_default_payment_method(kb_account_id, kb_payment_method_id, properties, context)
        pm = @payment_method_model.from_kb_payment_method_id(kb_payment_method_id, context.tenant_id)

        kb_pm = KbPaymentMethod.where(external_key: pm.kb_payment_method_id)
        kb_pm.each { |payment_method|
          account = Accounts.where(id: payment_method.account_id).first

          account.payment_method_id = payment_method.id
          account.save!

        }
      end

      def get_payment_methods(kb_account_id, refresh_from_gateway, properties, context)
        # Pass extra parameters for the gateway here
        options = {}

        properties = merge_properties(properties, options)
        options = properties_to_hash(properties)
        @payment_method_model.from_kb_account_id(kb_account_id, context.tenant_id).collect { |pm| pm.to_payment_method_info_plugin }
      end

      def build_form_descriptor(kb_account_id, descriptor_fields, properties, context)
        # Pass extra parameters for the gateway here
        options = {}
        properties = merge_properties(properties, options)

        # Add your custom static hidden tags here
        options = {
            #:token => config[:stripe][:token]
        }
        descriptor_fields = merge_properties(descriptor_fields, options)

        super(kb_account_id, descriptor_fields, properties, context)
      end

      def process_notification(notification, properties, context)
        # Pass extra parameters for the gateway here
        options = {}
        properties = merge_properties(properties, options)

        super(notification, properties, context) do |gw_notification, service|
          # Retrieve the payment
          # gw_notification.kb_payment_id =
          #
          # Set the response body
          # gw_notification.entity =
        end
      end

      private

      def get_payment_source(kb_payment_method_id, properties, options, context)
        return nil if options[:customer_id]

        attributes = properties_to_hash(properties, options)

        # Use ccNumber for:
        # * the real number
        # * in-house token (e.g. proxy tokenization)
        # * token from a token service provider (e.g. ApplePay)
        # If not specified, the rest of the card details will be retrieved from the locally stored payment method (if available)
        cc_number = Utils.normalized(attributes, :cc_number)
        # Use token for the token stored in an external vault. The token itself should be enough to process payments.
        token = Utils.normalized(attributes, :token) || Utils.normalized(attributes, :card_id) || Utils.normalized(attributes, :payment_data)

        if token.blank?
          pm = nil
          begin
            pm = @payment_method_model.from_kb_payment_method_id(kb_payment_method_id, context.tenant_id)
          rescue => e
            raise e if cc_number.blank?
          end unless kb_payment_method_id.nil?

          if cc_number.blank? && !pm.nil?
            # Lookup existing token
            if pm.token.nil?
              # Real credit card
              cc_or_token = build_am_credit_card(pm.cc_number, attributes, pm)
            else
              # Tokenized card
              cc_or_token = pm.token
            end
          else
            # Real credit card or network tokenization
            cc_or_token = build_am_credit_card(cc_number, attributes, pm)
          end
        else
          # Use specified token
          cc_or_token = build_am_token(token, attributes)
        end

        options[:billing_address] ||= {
            :email => Utils.normalized(attributes, :email),
            :address1 => Utils.normalized(attributes, :address1) || (pm.nil? ? nil : pm.address1),
            :address2 => Utils.normalized(attributes, :address2) || (pm.nil? ? nil : pm.address2),
            :city => Utils.normalized(attributes, :city) || (pm.nil? ? nil : pm.city),
            :zip => Utils.normalized(attributes, :zip) || (pm.nil? ? nil : pm.zip),
            :state => Utils.normalized(attributes, :state) || (pm.nil? ? nil : pm.state),
            :country => Utils.normalized(attributes, :country) || (pm.nil? ? nil : pm.country)
        }

        # To make various gateway implementations happy...
        options[:billing_address].each { |k, v| options[k] ||= v }

        cc_or_token
      end

      def dispatch_to_gateways(operation, kb_account_id, kb_payment_id, kb_payment_transaction_id, kb_payment_method_id, amount, currency, properties, context, gateway_call_proc, linked_transaction_proc=nil)
        kb_transaction        = Utils::LazyEvaluator.new { get_kb_transaction(kb_payment_id, kb_payment_transaction_id, context.tenant_id) }
        amount_in_cents       = amount.nil? ? nil : to_cents(amount, currency)

        # Setup options for ActiveMerchant
        options               = properties_to_hash(properties)
        options[:order_id]    ||= (Utils.normalized(options, :external_key_as_order_id) ? kb_transaction.external_key : kb_payment_transaction_id)
        options[:currency]    ||= currency.to_s.upcase unless currency.nil?
        options[:description] ||= "Kill Bill #{operation.to_s} for #{kb_payment_transaction_id}"

        # Retrieve the payment method
        payment_source        = get_payment_source(kb_payment_method_id, properties, options, context)

        # Sanity checks
        if [:authorize, :purchase, :credit].include?(operation)
          raise "Unable to retrieve payment source for operation=#{operation}, kb_payment_id=#{kb_payment_id}, kb_payment_transaction_id=#{kb_payment_transaction_id}, kb_payment_method_id=#{kb_payment_method_id}" if payment_source.nil?
        end

        # Retrieve the previous transaction for the same operation and payment id - this is useful to detect dups for example
        last_transaction = Utils::LazyEvaluator.new { @transaction_model.send("#{operation.to_s}s_from_kb_payment_id", kb_payment_id, context.tenant_id).last }

        # Retrieve the linked transaction (authorization to capture, purchase to refund, etc.)
        linked_transaction = nil
        unless linked_transaction_proc.nil?
          linked_transaction                     = linked_transaction_proc.call(amount_in_cents, options)
          options[:payment_processor_account_id] ||= linked_transaction.payment_processor_account_id
        end

        # Filter before all gateways call
        before_gateways(kb_transaction, last_transaction, payment_source, amount_in_cents, currency, options)

        # Dispatch to the gateways. In most cases (non split settlements), we only dispatch to a single gateway account
        gw_responses                  = []
        responses                     = []
        transactions                  = []

        payment_processor_account_ids = Utils.normalized(options, :payment_processor_account_ids)
        if !payment_processor_account_ids
          payment_processor_account_ids = [Utils.normalized(options, :payment_processor_account_id) || :default]
        else
          payment_processor_account_ids = payment_processor_account_ids.split(',')
        end
        payment_processor_account_ids.each do |payment_processor_account_id|
          # Find the gateway
          gateway = lookup_gateway(payment_processor_account_id, context.tenant_id)

          # Filter before each gateway call
          before_gateway(gateway, kb_transaction, last_transaction, payment_source, amount_in_cents, currency, options)

          # Perform the operation in the gateway
          gw_response           = gateway_call_proc.call(gateway, linked_transaction, payment_source, amount_in_cents, options)
          response, transaction = save_response_and_transaction(gw_response, operation, kb_account_id, context.tenant_id, payment_processor_account_id, kb_payment_id, kb_payment_transaction_id, operation.upcase, amount_in_cents, currency)

          # Filter after each gateway call
          after_gateway(response, transaction, gw_response)

          gw_responses << gw_response
          responses << response
          transactions << transaction
        end

        # Filter after all gateways call
        after_gateways(responses, transactions, gw_responses)

        # Merge data
        merge_transaction_info_plugins(payment_processor_account_ids, responses, transactions)
      end

      def get_destination(tenant_id)
        return Killbill::Plugin::ActiveMerchant.config(tenant_id)[:stripe][:stripe_destination]
      end

      def get_application_fee(amount)
        fees_percent = StripeApplicationFee.first.application_fee

        return (fees_percent * amount*100).to_i
      end




    end
  end
end
