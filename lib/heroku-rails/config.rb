require 'erb'

module HerokuRails
  class Config

    SEPERATOR = ":"

    class << self
      def root
        @heroku_rails_root || ENV["RAILS_ROOT"] || "."
      end
      def root=(root)
        @heroku_rails_root = root
      end
      def app_name(app, env)
        "#{app}#{SEPERATOR}#{env}"
      end
    end

    attr_accessor :settings

    def initialize(config_files)
      self.settings = aggregate_heroku_configs(config_files)
    end

    def apps
      self.settings['apps'] || []
    end

    def app_names
      apps.keys
    end

    # Returns the app name on heroku froma string format like so: `app:env>`
    # Allows for `rake <app:env> [<app:env>] <command>`
    def app_name_on_heroku(string)
      app_name, env = string.split(SEPERATOR)
      apps[app_name][env] 
    end

    # return all enviromnets in this format app:env
    def app_environments
      apps.each_with_object([]) do |(app, hsh), arr|
        hsh.each { |env, app_name| arr << self.class.app_name(app, env) }
      end
    end

    # return the stack setting for a particular app environment
    def stack(app_env)
      name, env = app_env.split(SEPERATOR)
      stacks = self.settings['stacks'] || {}
      (stacks[name] && stacks[name][env]) || stacks['all']
    end

    # pull out the config setting hash for a particular app environment
    def config(app_env)
      name, env = app_env.split(SEPERATOR)
      config = self.settings['config'] || {}
      all = config['all'] || {}

      app_configs = (config[name] && config[name].reject { |k,v| v.class == Hash }) || {} 
      # overwrite app configs with the environment specific ones
      merged_environment_configs = app_configs.merge((config[name] && config[name][env]) || {})

      # overwrite all configs with the environment specific ones
      all.merge(merged_environment_configs)
    end

    # return a list of domains for a particular app environment
    def domains(app_env)
      name, env = app_env.split(SEPERATOR)
      domains = self.settings['domains'] || {}
      (domains[name] && domains[name][env]) || []
    end

    # return a list of collaborators for a particular app environment
    def collaborators(app_env)
      app_setting_list('collaborators', app_env)
    end

    # return a list of addons for a particular app environment
    def addons(app_env)
      app_setting_list('addons', app_env)
    end

    protected

    def app_setting_list(setting_key, app_env)
      name, env = app_env.split(SEPERATOR)
      setting = self.settings[setting_key] || {}
      all = setting['all'] || []

      # add in collaborators from app environment to the ones defined in all
      (all + (setting[name][env] || [])).uniq
    end

    private 

    def parse_yml(config_filepath)
      YAML.load(ERB.new(File.read(config_filepath)).result) if File.exists?(config_filepath)
    end

    # Refactor: should capture filename as it correspond to the app, so configs could look like so
    # (without the app_name)
    # app: 
    #  staging: asdfasdf
    def aggregate_heroku_configs(config_files)
      config_files.each_with_object({}) do |config_file, hsh|
        # overwrite all configs with the environment specific ones 
        hsh.rmerge!(parse_yml(config_file))
      end
    end
  end
end