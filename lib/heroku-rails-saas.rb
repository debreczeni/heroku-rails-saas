require 'heroku-rails-saas/config'
require 'heroku-rails-saas/runner'
require 'heroku-rails-saas/railtie' if defined?(::Rails::Railtie)
require 'heroku-rails-saas/hash_recursive_merge'