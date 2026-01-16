module Katello
  class ContentViewManager
    def self.add_version_to_environment(content_view_version:, environment:)
      content_view = content_view_version.content_view
      if (cve = content_view.content_view_environment(environment))
        content_view_version.content_view_environments << cve
      else
        cve = content_view.add_environment(environment, content_view_version)
      end
      cve
    end

    def self.create_candlepin_environment(content_view_environment:)
      unless content_view_environment.exists_in_candlepin?
        ::Katello::Resources::Candlepin::Environment.create(
          content_view_environment.content_view.organization.label,
          content_view_environment.cp_id,
          content_view_environment.label,
          content_view_environment.content_view.description.try(:truncate, 255)
        )
      end
    end

    def self.auto_publish_composites!(content_view_version:)
      composites = content_view_version.content_view.publishable_composites
      return unless composites.any?

      composites.each do |composite|
        request = composite.build_auto_publish_request
        request.content_view_version = content_view_version

        begin
          request.save!

          # Trigger AutoPublish action (PR #11600's approach)
          ForemanTasks.async_task(
            ::Actions::Katello::ContentView::AutoPublish,
            request
          )
        rescue ActiveRecord::RecordNotUnique
          Rails.logger.info("Auto-publish already triggered for composite #{composite.name}, skipping")
          next
        end
      end
    end
  end
end
