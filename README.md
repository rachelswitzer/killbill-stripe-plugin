killbill-stripe-plugin
======================

Plugin to use [Stripe Connect](https://stripe.com/docs/connect) as a gateway for [KillBill.io](http://www.killbill.io).


Kill Bill compatibility
-----------------------

| Plugin version | Kill Bill version | Stripe version                                            |
| -------------: | ----------------: | --------------------------------------------------------: |
| 1.0.y          | 0.14.z            | [2015-02-18](https://stripe.com/docs/upgrades#2015-02-18) |

Requirements
------------

The plugin needs a database. The latest version of the schema can be found [here](https://github.com/rachelswitzer/killbill-stripe-plugin/blob/master/db/ddl.sql).

Configuration
-------------

```
curl -v \
     -X POST \
     -u admin:password \
     -H 'X-Killbill-ApiKey: bob' \
     -H 'X-Killbill-ApiSecret: lazar' \
     -H 'X-Killbill-CreatedBy: admin' \
     -H 'Content-Type: text/plain' \
     -d ':stripe:
  :api_secret_key: "your-secret-key"
  :api_publishable_key: "your-publishable-key"
  :stripe_destination: "your-stripe-destination-acct"' \
     http://127.0.0.1:8080/1.0/kb/tenants/uploadPluginConfig/killbill-stripe
```

You'll also need to add a row to the `stripe_application_fees` table and add a percent (such as .3 for 30%) to the `application_fee` field. Right now, the logic is just pulling the first active record and then using the `application_fee` field as a percent and calculating the application fee as a percentage on the purchase amount. My requirements have not been solidified yet, so this implementation is a placeholder to be built upon at a later date. You could easily add a `tenant_id` or `account_id` to the `stripe_application_fees` table so that you can set a percent based on a tenant or an account. You could also change the code to pull a dollar amount instead of calculating a percent of the purchase amount.

Also, in our implementation we needed to share the credit card information between tenants. We use the external_key on account table as an identifier that the account is owned by the same customer. If the external_keys match between tenants, we know they are related to the same customer. We would like them to have the same payment options for each tenant. So we had to do a bit of hacking in order to make this happen and not break any of the KillBill interfaces.

We have to add a record to the payment_method table to each matching account (where external_keys on the account are the same). This keeps KillBill happy so it knows how to find the payment. The external_key on the payment_method table will point to the id for the stripe_payment method table. Now the payment_method table uses the external_key to match to the id on the stripe_payment_table, we had to change the queries for getting the credit card token from stripe_payment_methods to look up based on the external_key.
This plugin will handle keeping all the records in sync each account for the follow: new adding payment methods, deleting payment methods and setting new default payment method. 
**TODO: When creating a user, sync up payment_method records and match to appropriate stripe_payment_method table.**


To get your credentials:

1. Go to [stripe.com](http://stripe.com/) and create an account. This account will be used as a sandbox environment for testing.
2. In your Stripe account, click on **Your Account** (top right), then click on **Account Settings** and then on the **API Keys** tab. Write down your keys.

To get a destination account:
1. Call the following...
```
curl https://api.stripe.com/v1/accounts \
-u sk_test_pzDxPUJ3QTIjGWdlPfz9UkfF: \
-d country=US \
-d managed=true
```
Or see [additional ways](https://stripe.com/docs/connect/managed-accounts#creating-a-managed-account) to setup a destination account. 

2. In the response, you'll get back an `id`. Use that `id` as your destination account.    

To go to production, create a `stripe.yml` configuration file under `/var/tmp/bundles/plugins/ruby/killbill-stripe/x.y.z/` containing the following:

```
:stripe:
  :test: false
```

Usage
-----

You would typically implement [Stripe.js](https://stripe.com/docs/stripe.js) to tokenize credit cards. 

After receiving the token from Stripe, call:

```
curl -v \
     -X POST \
     -u admin:password \
     -H 'X-Killbill-ApiKey: bob' \
     -H 'X-Killbill-ApiSecret: lazar' \
     -H 'X-Killbill-CreatedBy: admin' \
     -H 'Content-Type: application/json' \
     -d '{
       "pluginName": "killbill-stripe",
       "pluginInfo": {
         "properties": [{
           "key": "token",
           "value": "tok_20G53990M6953444J"
         }]
       }
     }' \
     "http://127.0.0.1:8080/1.0/kb/accounts/2a55045a-ce1d-4344-942d-b825536328f9/paymentMethods?isDefault=true"
```

An example implementation is exposed at:

```
http://127.0.0.1:8080/plugins/killbill-stripe?kb_account_id=2a55045a-ce1d-4344-942d-b825536328f9&kb_tenant_id=a86d9fd1-718d-4178-a9eb-46c61aa2548f
```
