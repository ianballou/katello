module Katello
  module Validators
    class RepositoryDistributionPathValidator
      def self.validate_create!(root, user:)
        return unless root.docker? && !root.is_container_push && root.product && root.name.present?

        organization = root.organization
        environment = organization&.library
        version = organization&.library&.default_content_view_version
        return unless environment && version

        # Match the label callback that will run when the root is saved.
        root.setup_label_from_name if root.label.blank?
        return if root.label.blank? || root.product.label.blank?
        projected_root = root.dup
        projected_root.product = root.product
        repository = Katello::Repository.new(root: projected_root, environment: environment, content_view_version: version)
        validate!(repository, path: Katello::Repository.safe_render_container_name(repository), user: user)
      end

      def self.validate_update!(root, repository, params, user:)
        return unless root.docker? && repository

        # Run the same validations and dirty tracking used by update! without saving.
        # pulp_update_needed? reads previous_changes, so supply the projected changes
        # on an isolated copy rather than duplicating its list of Pulp attributes.
        probe = root.class.find(root.id)
        probe.assign_attributes(root.changes_to_save.transform_values(&:last))
        probe.assign_attributes(params)
        return unless probe.valid?

        probe.define_singleton_method(:previous_changes) { changes_to_save }
        return unless probe.pulp_update_needed?

        validate_existing!(repository, user: user)
      end

      def self.validate_existing!(repository, user:)
        if repository.docker?
          validate!(repository, path: repository.container_repository_name, user: user)
        else
          references = Katello::Pulp3::DistributionReference.unscoped.joins(repository: :root)
            .where(Katello::RootRepository.table_name => {content_type: Katello::Repository::DOCKER_TYPE})
            .includes(:repository).to_a
          validate!(repository, path: repository.relative_path&.sub(%r{\A/}, ''), user: user, references: references)
        end
      end

      def self.validate!(repository, path:, user:, references: nil)
        return if path.blank? || path.delete('/').blank?

        candidate = DistributionPathValidator::Candidate.new(
          path: path,
          repository: repository,
          reference_id: repository.persisted? ? Katello::Pulp3::DistributionReference.find_by(repository_id: repository.id)&.id : nil
        )
        messages = DistributionPathValidator.messages(candidates: [candidate], organization: repository.organization, user: user, references: references)
        fail Katello::HttpErrors::Conflict, messages.join("  ") if messages.any?
      end
    end
  end
end
