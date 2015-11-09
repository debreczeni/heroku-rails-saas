require 'erb'

module HerokuRailsSaas
  class Config

    SEPARATOR = ":"

    class << self
      def root
        @heroku_rails_root || ENV["RAILS_ROOT"] || "."
      end

      def root=(root)
        @heroku_rails_root = root
      end

      def app_name(app, env)
        "#{app}#{SEPARATOR}#{env}"
      end

      def extract_environment_from(app_env)
        name, env = app_env.split(SEPARATOR)
        env
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

    # Returns the app name on heroku froma string format like so: `app:env`
    # Allows for `rake <app:env> [<app:env>] <command>`
    def app_name_on_heroku(string)
      app_name, env = string.split(SEPARATOR)
      apps[app_name][env]
    end

    # return all enviromnets in this format app:env
    def app_environments(env_filter="")
      apps.each_with_object([]) do |(app, hsh), arr|
        hsh.each { |env, app_name| arr << self.class.app_name(app, env) if (env_filter.nil? || env_filter.empty?) || env == env_filter }
      end
    end

    # return all environments e.g. staging, production, development
    def all_environments
      environments = apps.each_with_object([]) do |(app, hsh), arr|
        hsh.each { |env, app_name| arr << env }
      end
      environments.uniq
    end

    # return the stack setting for a particular app environment
    def stack(app_env)
      name, env = app_env.split(SEPARATOR)
      stack = settings['stack'] || {}
      (stack[name] && stack[name][env]) || stack['all']
    end

    def cmd(app_env)
      if self.stack(app_env) =~ /cedar/i
        'heroku run '
      else
        'heroku '
      end
    end

    # pull out the config setting hash for a particular app environment
    def config(app_env)
      name, env = app_env.split(SEPARATOR)
      config = self.settings['config'] || {}
      all = config['all'] || {}

      app_configs = (config[name] && config[name].reject { |k,v| v.class == Hash }) || {}
      # overwrite app configs with the environment specific ones
      merged_environment_configs = app_configs.merge((config[name] && config[name][env]) || {})

      # overwrite all configs with the environment specific ones
      all.merge(merged_environment_configs)
    end

    # pull out the scaling setting hash for a particular app environment
    def scale(app_env)
      name, env = app_env.split(SEPARATOR)
      scaling = self.settings['scale'] || {}
      all = scaling['all'] || {}

      app_scaling = (scaling[name] && scaling[name].reject { |k,v| v.class == Hash }) || {}
      # overwrite app scaling with the environment specific ones
      merged_environment_scaling = app_scaling.merge((scaling[name] && scaling[name][env]) || {})

      # overwrite all scaling with the environment specific ones
      all.merge(merged_environment_scaling)
    end

    # return a list of domains for a particular app environment
    def domains(app_env)
      name, env = app_env.split(SEPARATOR)
      domains = self.settings['domains'] || {}
      domains_from_app_config = (domains[name] && domains[name][env]) || []
      domains_from_global_config = (domains['all'] && domains['all'][env]) || []

      domains_from_app_config + domains_from_global_config
    end

    # return a list of collaborators for a particular app environment
    def collaborators(app_env)
      app_setting_list('collaborators', app_env)
    end

    # return a list of addons for a particular app environment
    def addons(app_env)
      addons_hash = {}
      app_setting_list('addons', app_env).each do |setting|
        name, slug = setting.split(':')
        addons_hash[name] = slug
      end
      addons_hash
    end

    protected

    def app_setting_list(setting_key, app_env)
      name, env = app_env.split(SEPARATOR)
      setting = self.settings[setting_key] || {}
      all = setting['all'] || []

      # add in collaborators from app environment to the ones defined in all
      (all + ((setting[name] && setting[name][env]) || [])).uniq
    end

    private

    def parse_yml(config_filepath, options)
      if File.exists?(config_filepath)
        config_hash = YAML.load(ERB.new(File.read(config_filepath)).result)
        config_hash = add_all_namespace(config_hash) if options == :default
        config_hash = add_app_namespace(File.basename(config_filepath, ".yml"), config_hash) if options == :apps
        config_hash
      end
    end

    def add_all_namespace(hsh)
      hsh.each_with_object({}) { |(k,v), h| h[k] = Hash["all" => v] }
    end

    def add_app_namespace(app_name, hsh)
      hsh["apps"] = hsh.delete("env") if hsh.has_key?("env")
      hsh.each_with_object({}) { |(k,v), h| h[k] = Hash[app_name => v] }
    end

    def aggregate_heroku_configs(config_files)
      hsh = {}
      config_files[:apps].each_with_object(hsh) { |file, h| h.rmerge!(parse_yml(file, :apps)) }
      # overwrite all configs with the environment specific ones
      hsh.rmerge!(parse_yml(config_files[:default], :default))
    end
  end
end
