# frozen_string_literal: true
require 'smart_proxy_dynflow/ticker'

module Proxy::Dynflow
  module Runner
    class Dispatcher
      def self.instance
        return @instance if @instance

        @instance = new(Proxy::Dynflow::Core.world.clock,
                        Proxy::Dynflow::Core.world.logger)
      end

      class RunnerActor < ::Dynflow::Actor
        def initialize(dispatcher, suspended_action, runner, clock, logger, _options = {})
          @dispatcher = dispatcher
          @clock = clock
          @ticker = dispatcher.ticker
          @logger = logger
          @suspended_action = suspended_action
          @runner = runner
          @finishing = false
        end

        def on_envelope(*args)
          super
        rescue => e
          handle_exception(e)
        end

        def start_runner
          @logger.debug("start runner #{@runner.id}")
          set_timeout if @runner.timeout_interval
          @runner.start
          refresh_runner
        ensure
          plan_next_refresh
        end

        def refresh_runner
          @logger.debug("refresh runner #{@runner.id}")
          dispatch_updates(@runner.run_refresh)
        ensure
          @refresh_planned = false
          plan_next_refresh
        end

        def refresh_output
          @logger.debug("refresh output #{@runner.id}")
          dispatch_updates(@runner.run_refresh_output)
        end

        def dispatch_updates(updates)
          updates.each { |receiver, update| (receiver || @suspended_action) << update }

          # This is a workaround when the runner does not accept the suspended action
          main_key = updates.keys.any?(&:nil?) ? nil : @suspended_action
          main_process = updates[main_key]
          finish if main_process&.exit_status
        end

        def timeout_runner
          @logger.debug("timeout runner #{@runner.id}")
          @runner.timeout
        rescue => e
          handle_exception(e, false)
        end

        def kill
          @logger.debug("kill runner #{@runner.id}")
          @runner.kill
        rescue => e
          handle_exception(e, false)
        end

        def finish
          @logger.debug("finish runner #{@runner.id}")
          @finishing = true
          @dispatcher.finish(@runner.id)
        end

        def start_termination(*args)
          @logger.debug("terminate #{@runner.id}")
          super
          @runner.close
          finish_termination
        end

        def external_event(event)
          dispatch_updates(@runner.external_event(event))
        end

        private

        def set_timeout
          timeout_time = Time.now.getlocal + @runner.timeout_interval
          @logger.debug("setting timeout for #{@runner.id} to #{timeout_time}")
          @clock.ping(reference, timeout_time, :timeout_runner)
        end

        def plan_next_refresh
          if !@finishing && !@refresh_planned
            @logger.debug("planning to refresh #{@runner.id}")
            @ticker.tell([:add_event, reference, :refresh_runner])
            @refresh_planned = true
          end
        end

        def handle_exception(exception, fatal = true)
          @dispatcher.handle_command_exception(@runner.id, exception, fatal)
        end
      end

      attr_reader :ticker

      def initialize(clock, logger)
        @mutex  = Mutex.new
        @clock  = clock
        @logger = logger
        @ticker = ::Proxy::Dynflow::Ticker.spawn('dispatcher-ticker', @clock, @logger, refresh_interval)
        @runner_actors = {}
        @runner_suspended_actions = {}
      end

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def start(suspended_action, runner)
        synchronize do
          raise "Actor with runner id #{runner.id} already exists" if @runner_actors[runner.id]

          runner.logger = @logger
          runner_actor = RunnerActor.spawn("runner-actor-#{runner.id}", self, suspended_action, runner, @clock, @logger)
          @runner_actors[runner.id] = runner_actor
          @runner_suspended_actions[runner.id] = suspended_action
          runner_actor.tell(:start_runner)
          return runner.id
        rescue => e
          _handle_command_exception(runner.id, e)
          return nil
        end
      end

      def kill(runner_id)
        synchronize do
          runner_actor = @runner_actors[runner_id]
          runner_actor&.tell(:kill)
        rescue => e
          _handle_command_exception(runner_id, e, false)
        end
      end

      def finish(runner_id)
        synchronize do
          _finish(runner_id)
        rescue => e
          _handle_command_exception(runner_id, e, false)
        end
      end

      def external_event(runner_id, external_event)
        synchronize do
          runner_actor = @runner_actors[runner_id]
          runner_actor&.tell([:external_event, external_event])
        end
      end

      def refresh_output(runner_id)
        synchronize do
          @runner_actors[runner_id]&.tell([:refresh_output])
        end
      end

      def handle_command_exception(*args)
        synchronize { _handle_command_exception(*args) }
      end

      def refresh_interval
        1
      end

      private

      def _finish(runner_id)
        runner_actor = @runner_actors.delete(runner_id)
        return unless runner_actor

        @logger.debug("closing session for command [#{runner_id}]," \
                      "#{@runner_actors.size} actors left ")
        runner_actor.tell([:start_termination, Concurrent::Promises.resolvable_future])
      ensure
        @runner_suspended_actions.delete(runner_id)
      end

      def _handle_command_exception(runner_id, exception, fatal = true)
        @logger.error("error while dispatching request to runner #{runner_id}:"\
                      "#{exception.class} #{exception.message}:\n #{exception.backtrace.join("\n")}")
        suspended_action = @runner_suspended_actions[runner_id]
        if suspended_action
          suspended_action << Runner::Update.encode_exception('Runner error', exception, fatal)
        end
        _finish(runner_id) if fatal
      end
    end
  end
end
