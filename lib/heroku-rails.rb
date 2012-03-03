require 'heroku-rails/config'
require 'heroku-rails/runner'
require 'heroku-rails/railtie' if defined?(::Rails::Railtie)
require 'heroku-rails/hash_recursive_merge'