require 'heroku/client'

module HerokuRailsSaas
  class Runner
    def initialize(config)
      @config = config
      @environments = []
    end

    def authorize
      @heroku ||= Heroku::Client.new(*Heroku::Auth.get_credentials)
    end

    # add a specific environment to the run list
    def add_environment(env)
      @environments << env
    end

    # use all environments or filter out production environments
    def all_environments(filter=false)
      @environments = @config.app_environments
      filter ? @environments.reject! { |app| app[regex_for(:production)] } : @environments
    end

    # use all heroku apps filtered by environments
    def environments(env)
      @environments = @config.app_environments(env)
    end

    # setup apps (create if necessary)
    def setup_apps
      authorize unless @heroku

      # get a list of all my current apps on Heroku (so we don't create dupes)
      @my_apps = @heroku.list.map{|a| a.first}

      each_heroku_app do |heroku_env, app_name, repo|
        next if @my_apps.include?(app_name)

        options = { :remote => app_name, :stack => @config.stack(heroku_env) }

        @heroku.create(app_name, options)
      end
    end

    # setup the stacks for each app (migrating if necessary)
    def setup_stacks
      authorize unless @heroku
      each_heroku_app do |heroku_env, app_name, repo|
        # get the intended stack setting
        stack = @config.stack(heroku_env)

        # get the remote info about the app from heroku
        heroku_app_info = @heroku.info(app_name) || {}

        # if the stacks don't match, then perform a migration
        if stack != heroku_app_info[:stack]
          puts "Migrating the app: #{app_name} to the stack: #{stack}"
          creation_command "heroku stack:migrate #{stack} --app #{app_name}"
        end
      end
    end

    # setup the list of collaborators
    def setup_collaborators
      authorize unless @heroku
      each_heroku_app do |heroku_env, app_name, repo|
        # get the remote info about the app from heroku
        heroku_app_info = @heroku.info(app_name) || {}

        # get the intended list of collaborators to add
        collaborator_emails = @config.collaborators(heroku_env)

        # add current user to collaborator list (always)
        collaborator_emails << @heroku.user unless collaborator_emails.include?(@heroku.user)
        collaborator_emails << heroku_app_info[:owner] unless collaborator_emails.include?(heroku_app_info[:owner])

        # get existing collaborators
        existing_emails = `heroku access -a #{app_name}`.lines.reject{ |a|
          !(a =~ /collaborator|owner/)
        }.map{ |l| l.split(' ').first }

        # get the list of collaborators to delete
        existing_emails.each do |existing_email|
          # check to see if we need to delete this person
          unless collaborator_emails.include?(existing_email)
            # delete that collaborator if they arent on the approved list
            destroy_command "heroku access:remove #{existing_email} --app #{app_name}"
          end
        end

        # get the list of collaborators to add
        collaborator_emails.each do |collaborator_email|
          # check to see if we need to add this person
          unless existing_emails.include?(collaborator_email)
            # add the collaborator if they are not already on the server
            creation_command "heroku access:add #{collaborator_email} --app #{app_name}"
          end
        end

        # display the destructive commands
        output_destroy_commands(app_name)
      end
    end

    # setup configuration
    def setup_config
      authorize unless @heroku
      each_heroku_app do |app_env, app_name, repo|
        # get the configuration that we are aiming towards
        new_config = @config.config(app_env)

        # default RACK_ENV and RAILS_ENV to the heroku_env (unless its manually set to something else)
        new_config["RACK_ENV"]  = HerokuRailsSaas::Config.extract_environment_from(app_env) unless new_config["RACK_ENV"]
        new_config["RAILS_ENV"] = HerokuRailsSaas::Config.extract_environment_from(app_env) unless new_config["RAILS_ENV"]
        # get the existing config from heroku's servers
        existing_config = @heroku.config_vars(app_name) || {}

        # find the config variables to add
        add_config = {}
        new_config.each do |new_key, new_val|
          add_config[new_key] = new_val unless existing_config[new_key] == new_val
        end

        # persist the changes onto heroku
        unless add_config.empty?
          # add the config
          set_config = ""
          add_config.each do |key, val|
            set_config << "#{key}='#{val}' "
          end
          creation_command "heroku config:add #{set_config} --app #{app_name}"

          # unless on a newly created app
          clear_cache app_name unless @heroku.releases(app_name).last['commit'].nil?
        end

      end
    end

    def addon_full_name(name, slug)
      "#{name}#{slug.nil? || slug.empty? ? "" : ":"}#{slug}"
    end

    # setup the addons for heroku
    def setup_addons
      authorize unless @heroku
      each_heroku_app do |heroku_env, app_name, repo|
        addons_in_config = @config.addons(heroku_env)

        addons_on_heroku = {}
        (@heroku.installed_addons(app_name) || []).each do |installed_addon|
          name, slug = installed_addon['name'].split(':')
          addons_on_heroku[name] = slug
        end

        addons_on_heroku.each do |name, slug|
          if addons_in_config.include?(name)
            unless addons_in_config[name] == slug
              upgrade_command "heroku addons:upgrade #{addon_full_name(name,addons_in_config[name])} --app #{app_name} --confirm #{app_name}"
            end
          else
            destroy_command "heroku addons:remove #{addon_full_name(name,slug)} --app #{app_name} --confirm #{app_name}"
          end
        end

        addons_in_config.each do |name, slug|
          unless addons_on_heroku.include?(name)
            creation_command "heroku addons:add #{addon_full_name(name,slug)} --app #{app_name}"
          end
        end

        output_upgrade_commands(app_name)
        output_destroy_commands(app_name)
      end
    end

    # setup the domains for heroku
    def setup_domains
      authorize unless @heroku
      each_heroku_app do |heroku_env, app_name, repo|
        # get the domains that we are aiming towards
        domains = @config.domains(heroku_env)

        # get the domains that are already on the servers
        existing_domains = (@heroku.list_domains(app_name) || []).map{|a| a[:domain]}

        # remove the domains that need to be removed
        existing_domains.each do |existing_domain|
          # check to see if we need to delete this domain
          unless domains.include?(existing_domain)
            # delete this domain if they arent on the approved list
            destroy_command "heroku domains:remove #{existing_domain} --app #{app_name}"
          end
        end

        # add the domains that dont exist already
        domains.each do |domain|
          # check to see if we need to add this domain
          unless existing_domains.include?(domain)
            # add this domain if they are not already added
            creation_command "heroku domains:add #{domain} --app #{app_name}"
          end
        end

        # display the destructive commands
        output_destroy_commands(app_name)
      end
    end

    def clear_cache app_name
      system_with_echo("heroku run \"#{rails_cli(:runner)} \\\"Rails.cache.clear\\\"\" --app #{app_name}")
    end

    def scale
      authorize unless @heroku
      each_heroku_app do |heroku_env, app_name, repo|
        scaling = @config.scale(heroku_env)
        scaling.each do |process_name, dyno_conf|
          begin
            puts "Scaling app #{app_name} process #{process_name} to #{dyno_conf}"
            response = @heroku.ps_scale(app_name,
                                        type: process_name,
                                        qty:  dyno_conf[0],
                                        size: dyno_conf[1]
                                       )
            puts "Response: #{response}"
          rescue => e
            puts "Failed to scale #{app_name}. Error: #{e.inspect}"
          end
        end
      end
    end

    # cycles through each configured heroku app
    # yields the environment name, the app name, and the repo url
    def each_heroku_app

      if @config.apps.size == 0
        puts "\nNo heroku apps are configured. Run:
          rails generate heroku:config\n\n"
        puts "this will generate a default config/heroku.yml that you should edit"
        puts "and then try running this command again"

        exit(1)
      end

      if (@environments.nil? || @environments.empty?) && @config.apps.size == 1
        @environments = [all_environments(true).try(:first)].compact
      end

      if @environments.present?
        @environments.each do |env|
          app_name = @config.app_name_on_heroku(env)
          yield(env, app_name, "git@heroku.com:#{app_name}.git")
        end
      else
        puts "\nYou must first specify at least one Heroku app:
          rake <app>:<environment> [<app>:<environment>] <command>
          rake awesomeapp:production restart
          rake demo:staging deploy"

        puts "\n\nYou can use also command all Heroku apps(except production environments) for this project:
          rake all heroku:setup\n"

        exit(1)
      end
    end

    def system_with_echo(*args)
      puts args.join(' ')
      command(*args)
    end

    def creation_command(*args)
      system_with_echo(*args)
    end

    def destroy_command(*args)
      # puts args.join(' ')
      @destroy_commands ||= []
      @destroy_commands << args.join(' ')
    end

    def output_destroy_commands(app)
      if @destroy_commands.try(:any?)
        puts "The #{app} had a few things removed from heroku.yml."
        puts "If they are no longer neccessary, then run the following commands:\n\n"
        @destroy_commands.each do |destroy_command|
          puts destroy_command
        end
        puts "\n\nthese commands may cause data loss so make sure you know that these are necessary"
      end
      # clear destroy commands
      @destroy_commands = []
    end

    def upgrade_command(*args)
      @upgrade_commands ||= []
      @upgrade_commands << args.join(' ')
    end

    def output_upgrade_commands(app)
      if @upgrade_commands.try(:any?)
        puts "The #{app} had a few things changed in heroku.yml"
        puts "To apply these changes run the following commands:\n\n"
        @upgrade_commands.each do |upgrade_command|
          puts upgrade_command
        end
      end
      @upgrade_commands = []
    end

    def command(*args)
      unless system(*args)
        raise "*** command \"#{args.join ' '}\" failed" unless ENV['STRICT_DEPLOY'] == '0'
      end
    end

    def regex_for env
      match = case env
        when :production then "production|prod|live"
        when :staging    then "staging|stage"
      end
      Regexp.new("#{@config.class::SEPARATOR}(#{match})")
    end

    def rails_cli script
      Rails::VERSION::MAJOR < 3 ? "./script/#{script}" : "rails #{script}"
    end

  end
end
