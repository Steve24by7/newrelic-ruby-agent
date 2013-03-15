# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

# Listen for ActiveSupport::Notifications events for ActionView render
# events.  Write metric data and transaction trace segments for each event.
require 'new_relic/agent/instrumentation/rails4/evented_subscriber'

module NewRelic
  module Agent
    module Instrumentation
      class ActionViewSubscriber < EventedSubscriber
        def start(name, id, payload)
          event = RenderEvent.new(name, Time.now, nil, id, payload)
          push_event(event)

          if NewRelic::Agent.is_execution_traced? && event.recordable?
            event.scope = NewRelic::Agent.instance.stats_engine \
              .push_scope(event.metric_name, event.time)
          end
        end

        def finish(name, id, payload)
          event = pop_event(id)

          if NewRelic::Agent.is_execution_traced? && event.recordable?
            record_metrics(event)
            NewRelic::Agent.instance.stats_engine \
              .pop_scope(event.scope, event.duration, event.end)
          end
        end

        def record_metrics(event)
          NewRelic::Agent.instance.stats_engine \
            .record_metrics(event.metric_name,
                            Helper.milliseconds_to_seconds(event.duration),
                            :scoped => true)
        end

        if defined?(ActiveSupport::Notifications::Event)
          class RenderEvent < ActiveSupport::Notifications::Event
            attr_accessor :parent, :scope

            # Nearly every "render_blah.action_view" event has a child
            # in the form of "!render_blah.action_view".  The children
            # are the ones we want to record.  There are a couple
            # special cases of events without children.
            def recordable?
              name[0] == '!' ||
                metric_name == 'View/text template/Rendering' ||
                metric_name == 'View/(unknown)/Partial'
            end

            def metric_name
              if parent && (payload[:virtual_path] ||
                  (parent.payload[:identifier] =~ /template$/))
                return parent.metric_name
              elsif payload[:virtual_path]
                identifier = payload[:virtual_path]
              else
                identifier = payload[:identifier]
              end

              # memoize
              @metric_name ||= "View/#{metric_path(identifier)}/#{metric_action(name)}"
              @metric_name
            end

            def metric_path(identifier)
              if identifier == nil
                'file'
              elsif identifier =~ /template$/
                identifier
              elsif (parts = identifier.split('/')).size > 1
                parts[-2..-1].join('/')
              else
                '(unknown)'
              end
            end

            def metric_action(name)
              case name
              when /render_template.action_view$/  then 'Rendering'
              when 'render_partial.action_view'    then 'Partial'
              when 'render_collection.action_view' then 'Partial'
              end
            end
          end
        end
      end
    end
  end
end

DependencyDetection.defer do
  @name = :rails4_view

  depends_on do
    defined?(::Rails) && ::Rails::VERSION::MAJOR.to_i == 4
  end

  depends_on do
    !NewRelic::Agent.config[:disable_view_instrumentation] &&
      !NewRelic::Agent::Instrumentation::ActionViewSubscriber.subscribed?
  end

  executes do
    ::NewRelic::Agent.logger.info 'Installing Rails 4 view instrumentation'
  end

  executes do
    NewRelic::Agent::Instrumentation::ActionViewSubscriber.subscribe(/render_.+\.action_view$/)
  end
end
