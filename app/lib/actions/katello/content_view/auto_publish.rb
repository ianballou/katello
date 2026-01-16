module Actions
  module Katello
    module ContentView
      class AutoPublish < Actions::EntryAction
        include Dynflow::Action::Polling

        def plan(auto_publish_request)
          action_subject(auto_publish_request)

          plan_self(auto_publish_request_id: auto_publish_request.id)
        end

        def content_view_locks(content_view_id)
          ForemanTasks::Lock.where(
            resource_id: content_view_id,
            resource_type: ::Katello::ContentView.to_s)
        end

        def done?
          external_task.present? # Was the async task started?
        end

        def poll_external_task
          initiate_external_action
        end

        def invoke_external_task
          request = ::Katello::ContentViewAutoPublishRequest.find(input[:auto_publish_request_id])
          composite_cv = request.content_view

          # POLLING CHECK 1: Check for already scheduled composite publish
          # If another AutoPublish task already triggered a composite publish, wait for it
          has_scheduled_composite_publish = ForemanTasks::Task::DynflowTask
            .for_action(::Actions::Katello::ContentView::Publish)
            .where(state: 'scheduled')
            .any? do |task|
              begin
                delayed_plan = ForemanTasks.dynflow.world.persistence.load_delayed_plan(task.external_id)
                args = delayed_plan.args
                args.first.is_a?(::Katello::ContentView) && args.first.id == composite_cv.id
              rescue StandardError
                false
              end
            end

          if has_scheduled_composite_publish
            Rails.logger.info("Composite CV #{composite_cv.name} publish already scheduled, skipping")
            # Return a placeholder task hash so done? returns true and this action completes
            # The scheduled publish will use latest component versions when it executes
            return { id: 'skipped', state: 'skipped' }
          end

          # POLLING CHECK 2: Check for locks (original PR #11600 logic)
          if content_view_locks(composite_cv.id).any?
            Rails.logger.info "Locks found on composite CV, sleeping"
            return nil # Keep polling
          end

          # CHAINING LOGIC: Find running component CV publish tasks
          component_cv_ids = composite_cv.components.pluck(:content_view_id)
          running_tasks = ForemanTasks::Task::DynflowTask
            .for_action(::Actions::Katello::ContentView::Publish)
            .where(state: ['planning', 'planned', 'running'])
            .select do |task|
              task_input = task.input
              task_input && component_cv_ids.include?(task_input.dig('content_view', 'id'))
            end

          sibling_task_ids = running_tasks.map(&:external_id)

          # Trigger composite publish
          description = _("Auto Publish - Triggered by '%s'") % request.content_view_version.name

          begin
            if sibling_task_ids.any?
              # CHAINING: Chain to wait for component CVs
              return ForemanTasks.dynflow.world.chain(
                sibling_task_ids,
                Publish,
                composite_cv,
                description,
                triggered_by_id: request.content_view_version_id
              ).as_json
            else
              # No component CVs running, publish immediately
              return ForemanTasks.async_task(
                Publish,
                composite_cv,
                description,
                triggered_by_id: request.content_view_version_id
              ).as_json
            end
          rescue ForemanTasks::Lock::LockConflict
            Rails.logger.info "Got a lock conflict, sleeping"
            nil # Keep polling
          end
        end

        def finalize
          request = ::Katello::ContentViewAutoPublishRequest.find(input[:auto_publish_request_id])
          request.destroy!
        end
      end
    end
  end
end
