# frozen_string_literal: true
require 'fileutils'

module Proxy::Dynflow
  class Core
    attr_accessor :world, :accepted_cert_serial

    def initialize
      @world = create_world
      cert_file = Proxy::SETTINGS.foreman_ssl_cert || Proxy::SETTINGS.ssl_certificate
      if cert_file
        client_cert = File.read(cert_file)
        # we trust only requests using the same certificate as we are
        # (in other words the local proxy only)
        @accepted_cert_serial = OpenSSL::X509::Certificate.new(client_cert).serial
      end
    end

    def create_world(&block)
      config = default_world_config(&block)
      world = ::Dynflow::World.new(config)
      world.middleware.use ::Actions::Middleware::KeepCurrentRequestID
      world
    end

    def persistence_conn_string
      return ENV['DYNFLOW_DB_CONN_STRING'] if ENV.key? 'DYNFLOW_DB_CONN_STRING'

      db_conn_string = 'sqlite:/'

      db_file = Settings.instance.database
      if db_file.nil? || db_file.empty?
        Log.instance.info "Using in-memory database (default behaviour). Restart will drop all dynflow data. " \
                          "To change this behaviour configure setting 'database'."
      else
        FileUtils.mkdir_p(File.dirname(db_file))
        db_conn_string += "/#{db_file}"
      end

      db_conn_string
    end

    def persistence_adapter
      ::Dynflow::PersistenceAdapters::Sequel.new persistence_conn_string
    end

    def default_world_config
      ::Dynflow::Config.new.tap do |config|
        config.auto_rescue = true
        config.logger_adapter = logger_adapter
        config.persistence_adapter = persistence_adapter
        config.execution_plan_cleaner = execution_plan_cleaner
        # TODO: There has to be a better way
        matchers = config.silent_dead_letter_matchers.call.concat(self.class.silencer_matchers)
        config.silent_dead_letter_matchers = matchers
        yield config if block_given?
      end
    end

    def logger_adapter
      Log::ProxyAdapter.new(Proxy::LogBuffer::Decorator.instance, Log.instance.level)
    end

    def execution_plan_cleaner
      proc do |world|
        age = Settings.instance.execution_plan_cleaner_age
        options = { :poll_interval => age, :max_age => age }
        ::Dynflow::Actors::ExecutionPlanCleaner.new(world, options)
      end
    end

    class << self
      attr_reader :instance

      def ensure_initialized
        return @instance if @instance

        @instance = Core.new
        after_initialize_blocks.each { |block| block.call(@instance) }
        @instance
      end

      def silencer_matchers
        @matchers ||= [::Dynflow::DeadLetterSilencer::Matcher.new(Ticker)]
      end

      def register_silencer_matchers(matchers)
        silencer_matchers.concat matchers
      end

      def web_console
        require 'dynflow/web'
        ::Dynflow::Web.setup do
          # we can't use the proxy's after_activation hook, as
          # it happens before the Daemon forks the process (including
          # closing opened file descriptors)
          # TODO: extend smart proxy to enable hooks that happen after
          # the forking
          helpers Helpers
          include ::Sinatra::Authorization::Helpers

          before do
            do_authorize_with_ssl_client if Settings.instance.console_auth
          end

          Core.ensure_initialized
          set :world, Core.world
        end
      end

      def world
        instance.world
      end

      def after_initialize(&block)
        after_initialize_blocks << block
      end

      private

      def after_initialize_blocks
        @after_initialize_blocks ||= []
      end
    end
  end
end
