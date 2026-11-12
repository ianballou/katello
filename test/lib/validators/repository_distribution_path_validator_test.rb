require 'katello_test_helper'

module Katello
  class RepositoryDistributionPathValidatorTest < ActiveSupport::TestCase
    include Dynflow::Testing

    Validator = Validators::RepositoryDistributionPathValidator

    def setup
      @previous_user = User.current
      User.current = users(:admin)
      @repo = katello_repositories(:busybox)
      @other = katello_repositories(:redis)
      @repo.update_column(:container_repository_name, 'legacy/parent')
      @repo.reload
      Katello::Pulp3::DistributionReference.delete_all
    end

    def teardown
      User.current = @previous_user
    end

    def reference(repository, path, href)
      Katello::Pulp3::DistributionReference.create!(repository: repository, path: path, href: href)
    end

    def add_legacy_overlap
      reference(@repo, 'legacy/parent', '/pulp/dist/own/')
      reference(@other, 'legacy/parent/child', '/pulp/dist/other/')
    end

    test 'create checks projected library path before root is saved and redacts unsaved candidate' do
      root = Katello::RootRepository.new(name: 'New Image', label: 'new_image', content_type: 'docker', product: @repo.product,
                                          unprotected: true, download_policy: 'immediate')
      projected_root = root.dup
      projected_root.product = root.product
      projected = Katello::Repository.new(root: projected_root, environment: root.organization.library,
                                          content_view_version: root.organization.library.default_content_view_version)
      path = Katello::Repository.safe_render_container_name(projected)
      reference(@other, "#{path}/child", '/pulp/dist/other/')
      action = create_action(::Actions::Katello::Repository::CreateRoot)
      action.expects(:action_subject).never

      error = assert_raises(Katello::HttpErrors::Conflict) { action.plan(root) }
      assert_not root.persisted?
      assert_empty root.association(:repositories).target
      assert_not_includes error.message, path
      assert_not_includes error.message, @other.name
    end

    test 'create without a root product preserves the root save behavior' do
      baseline_root = Katello::RootRepository.new(name: 'No Product', content_type: 'docker')
      baseline_error = assert_raises(Module::DelegationError) { baseline_root.save! }
      root = Katello::RootRepository.new(name: 'No Product', content_type: 'docker')
      action = create_action(::Actions::Katello::Repository::CreateRoot)
      assert_raises(baseline_error.class) { action.plan(root) }
      assert_nil root.id
    end

    test 'creation without a root product keeps normal validation behavior' do
      root = Katello::RootRepository.new(name: 'No Product', content_type: 'docker')
      assert_nothing_raised { Validator.validate_create!(root, user: User.current) }
      assert_nil root.product
      assert_empty root.association(:repositories).target
    end

    test 'creation preflight does not associate the projected repository with the root' do
      root = Katello::RootRepository.new(name: 'New Image', content_type: 'docker', product: @repo.product,
                                          unprotected: true, download_policy: 'immediate')
      root.repositories.load
      assert_nothing_raised { Validator.validate_create!(root, user: User.current) }
      assert_empty root.repositories
      assert_nil root.id
    end

    test 'unchanged current path is checked before root update and is not recomputed for upstream edits' do
      add_legacy_overlap
      root = @repo.root
      old_upstream = root.docker_upstream_name
      action = create_action(::Actions::Katello::Repository::Update)
      action.stubs(:action_subject)
      action.expects(:plan_action).never

      assert_raises(Katello::HttpErrors::Conflict) { action.plan(root, docker_upstream_name: 'safe/new/upstream') }
      assert_equal old_upstream, root.reload.docker_upstream_name
      assert_equal 'legacy/parent', @repo.reload.container_repository_name
    end

    test 'update ignores unrelated no-write changes and unchanged pulp fields' do
      add_legacy_overlap
      assert_nothing_raised { Validator.validate_update!(@repo.root, @repo, {description: 'new description'}, user: User.current) }
      assert_nothing_raised { Validator.validate_update!(@repo.root, @repo, {docker_upstream_name: @repo.root.docker_upstream_name}, user: User.current) }
    end

    test 'safe current path is not blocked by unrelated old overlaps' do
      reference(@repo, 'legacy/parent', '/pulp/dist/own/')
      reference(@other, 'legacy/parent/child', '/pulp/dist/other/')
      @repo.update_column(:container_repository_name, 'repaired/path')
      @repo.reload
      assert_nothing_raised { Validator.validate_update!(@repo.root, @repo, {docker_upstream_name: 'new/upstream'}, user: User.current) }
    end

    test 'only the chosen distribution reference is excluded' do
      reference(@repo, 'legacy/parent', '/pulp/dist/own/')
      reference(@repo, 'legacy/parent/child', '/pulp/dist/second/')
      assert_raises(Katello::HttpErrors::Conflict) { Validator.validate_existing!(@repo, user: User.current) }
    end

    test 'restricted or anonymous users cannot see paths or repository names' do
      add_legacy_overlap
      Katello::Repository.stubs(:readable_as).with(users(:restricted)).returns(Katello::Repository.none)
      [users(:restricted), users(:anonymous), nil].each do |user|
        error = assert_raises(Katello::HttpErrors::Conflict) { Validator.validate_existing!(@repo, user: user) }
        assert_not_includes error.message, 'legacy/parent'
        assert_not_includes error.message, @other.name
      end
    end

    test 'sync checks the current distribution before any Pulp work is planned' do
      add_legacy_overlap
      action = create_action(::Actions::Katello::Repository::Sync)
      action.stubs(:action_subject)
      @repo.stubs(:check_ready_to_act!)
      action.expects(:plan_action).never
      assert_raises(Katello::HttpErrors::Conflict) { action.plan(@repo) }
    end

    test 'checksum verification does not preflight a distribution it will not write' do
      add_legacy_overlap
      action = create_action(::Actions::Katello::Repository::Sync)
      action.stubs(:action_subject)
      @repo.stubs(:check_ready_to_act!)
      plan_action(action, @repo, validate_contents: true)
      assert_action_planned_with(action, ::Actions::Katello::Repository::VerifyChecksum, @repo)
    end

    test 'docker candidate conflicts with a file distribution' do
      file_repo = katello_repositories(:generic_file)
      reference(file_repo, 'legacy/parent/child', '/pulp/dist/file/')

      assert_raises(Katello::HttpErrors::Conflict) { Validator.validate_existing!(@repo, user: User.current) }
    end

    test 'file candidate conflicts with a docker distribution using its relative path' do
      file_repo = katello_repositories(:generic_file)
      file_repo.update_column(:relative_path, '/legacy/parent/child')
      file_repo.reload
      reference(@repo, 'legacy/parent', '/pulp/dist/docker/')

      assert_raises(Katello::HttpErrors::Conflict) { Validator.validate_existing!(file_repo, user: User.current) }
    end

    test 'file candidate passes its stripped path, own reference, and only docker references to the checker' do
      file_repo = katello_repositories(:generic_file)
      file_repo.update_column(:relative_path, '/legacy/parent/child')
      file_repo.reload
      own = reference(file_repo, 'legacy/parent/child', '/pulp/dist/own/')
      docker = reference(@repo, 'legacy/parent', '/pulp/dist/docker/')
      reference(katello_repositories(:pulp3_file_1), 'legacy/parent/child', '/pulp/dist/file/')
      Validators::DistributionPathValidator.expects(:messages).with do |args|
        assert_equal 'legacy/parent/child', args[:candidates].first.path
        assert_equal own.id, args[:candidates].first.reference_id
        assert_equal [docker.id], args[:references].map(&:id)
        assert_equal User.current, args[:user]
        true
      end.returns([])

      Validator.validate_existing!(file_repo, user: User.current)
    end

    test 'file candidate ignores overlapping non-container distributions' do
      file_repo = katello_repositories(:generic_file)
      file_repo.update_column(:relative_path, '/legacy/parent')
      file_repo.reload
      reference(file_repo, 'legacy/parent', '/pulp/dist/own/')
      reference(katello_repositories(:pulp3_file_1), 'legacy/parent/child', '/pulp/dist/file/')
      reference(katello_repositories(:fedora_17_unpublished), 'legacy/parent/other', '/pulp/dist/yum/')

      assert_nothing_raised { Validator.validate_existing!(file_repo, user: User.current) }
    end

    test 'file candidate conflict does not disclose paths or names to restricted users' do
      file_repo = katello_repositories(:generic_file)
      file_repo.update_column(:relative_path, '/legacy/parent/child')
      file_repo.reload
      reference(@repo, 'legacy/parent', '/pulp/dist/docker/')
      Katello::Repository.stubs(:readable_as).with(users(:restricted)).returns(Katello::Repository.none)

      [users(:restricted), users(:anonymous), nil].each do |user|
        error = assert_raises(Katello::HttpErrors::Conflict) { Validator.validate_existing!(file_repo, user: user) }
        assert_not_includes error.message, 'legacy/parent'
        assert_not_includes error.message, @repo.name
        assert_not_includes error.message, file_repo.name
      end
    end
  end
end
