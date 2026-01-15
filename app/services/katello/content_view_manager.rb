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

    def self.auto_publish_composites!(content_view_version:, calling_task_id: nil)
      # Use publishable_composites (fixed in 6c7f79b9f2) instead of auto_publish_composites
      composites = content_view_version.content_view.publishable_composites
      return unless composites.any?

      description = _("Auto Publish - Triggered by '%s'") % content_view_version.name

      composites.each do |composite|
        # Use request model for deduplication ONLY
        # The request persists until the composite Publish task actually starts
        request = composite.build_auto_publish_request
        request.content_view_version = content_view_version

        begin
          # This will raise RecordNotUnique if another component already triggered
          request.save!

          # Use ALL existing chaining logic (including scheduled composite checks)
          # Request will be cleaned up by trigger_composite_publish_with_coordination
          ::Katello::ContentViewVersion.trigger_composite_publish_with_coordination(
            composite,
            description,
            content_view_version.id,
            calling_task_id: calling_task_id,
            auto_publish_request: request
          )
        rescue ActiveRecord::RecordNotUnique
          # Another component already triggered auto-publish for this composite
          Rails.logger.info("Auto-publish already triggered for composite #{composite.name}, skipping")
          next
        end
      end
    end
  end
end
