module Killbill #:nodoc:
  module Stripe #:nodoc:
    require 'active_record'
    require 'active_merchant'
    require 'money'
    require 'time'
    require 'killbill/helpers/active_merchant/active_record/models/helpers'
    class KbPaymentMethod  < ::ActiveRecord::Base

      extend ::Killbill::Plugin::ActiveMerchant::Helpers

      self.table_name = 'payment_methods'
      self.primary_key = 'id'
    end
  end
end
