#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.



class PromotionChangeset < Changeset
  use_index_of Changeset

  def apply(options = { })
    options = { :async => true, :notify => false }.merge options

    self.state == Changeset::REVIEW or
        raise _("Cannot promote the changset '%s' because it is not in the review phase.") % self.name

    #check for other changesets promoting
    if self.environment.promoting_to?
      raise _("Cannot promote the changeset '%s' while another changeset (%s) is being promoted.") %
                [self.name, self.environment.promoting.first.name]
    end

    # check that solitare repos in the changeset and its templates
    # will have its associated product in the env as well after promotion
    repos_to_be_promoted.each do |repo|
      if not self.environment.products.to_a.include? repo.product and not products_to_be_promoted.include? repo.product
        raise _("Cannot promote the changset '%s' because the repo '%s' does not belong to any promoted product.") %
                  [self.name, repo.name]
      end
    end

    validate_content! self.errata
    validate_content! self.packages
    validate_content! self.distributions

    self.state = Changeset::PROMOTING
    self.save!

    if options[:async]
      task             = self.async(:organization => self.environment.organization).promote_content(options[:notify])
      self.task_status = task
      self.save!
      self.task_status
    else
      self.task_status = nil
      self.save!
      promote_content(options[:notify])
    end
  end

  def promote_content(notify = false)
    update_progress! '0'
    self.calc_and_save_dependencies

    update_progress! '10'

    from_env = self.environment.prior
    to_env   = self.environment

    PulpTaskStatus::wait_for_tasks promote_products(from_env, to_env)
    update_progress! '30'
    PulpTaskStatus::wait_for_tasks promote_templates(from_env, to_env)
    update_progress! '50'
    PulpTaskStatus::wait_for_tasks promote_repos(from_env, to_env)
    update_progress! '70'
    to_env.update_cp_content
    update_progress! '80'
    promote_packages from_env, to_env
    update_progress! '90'
    promote_errata from_env, to_env
    update_progress! '95'
    promote_distributions from_env, to_env
    update_progress! '100'

    PulpTaskStatus::wait_for_tasks generate_metadata from_env, to_env

    self.promotion_date = Time.now
    self.state          = Changeset::PROMOTED
    self.save!

    index_repo_content to_env

    if notify
      message = _("Successfully promoted changeset '%s'.") % self.name
      Notify.message message, :request_type => "changesets___promote"
    end

  rescue Exception => e
    self.state = Changeset::FAILED
    self.save!
    Rails.logger.error(e)
    Rails.logger.error(e.backtrace.join("\n"))
    if notify
      Notify.exception _("Failed to promote changeset '%s'. Check notices for more details") % self.name, e,
                   :request_type => "changesets___promote"
    end
    index_repo_content to_env
    raise e
  end


  def promote_templates from_env, to_env
    async_tasks = self.system_templates.collect do |tpl|
      tpl.promote from_env, to_env
    end
    async_tasks.flatten(1)
  end


  def promote_products from_env, to_env
    async_tasks = self.products.collect do |product|
      product.promote from_env, to_env
    end
    async_tasks.flatten(1)
  end


  def promote_repos from_env, to_env
    async_tasks = []
    self.repos.each do |repo|
      product = repo.product
      next if (products.uniq! or []).include? product

      async_tasks << repo.promote(from_env, to_env)
    end
    async_tasks.flatten(1)
  end

  def promote_packages from_env, to_env
    #repo->list of pkg_ids
    pkgs_promote = { }

    (not_included_packages + dependencies).each do |pkg|
      product = pkg.product

      product.repos(from_env).each do |repo|
        if repo.is_cloned_in? to_env
          clone = repo.get_clone to_env

          if (repo.has_package? pkg.package_id) and (!clone.has_package? pkg.package_id)
            pkgs_promote[clone] ||= []
            pkgs_promote[clone] << pkg.package_id
          end
        end
      end
    end
    pkg_ids = []

    pkgs_promote.each_pair do |repo, pkgs|
      pkg_ids.concat(pkgs)
      pkgs_promote[repo] = Glue::Pulp::Package.id_search(pkgs)
    end
    Glue::Pulp::Repo.add_repo_packages(pkgs_promote)
    Glue::Pulp::Package.index_packages(pkg_ids)
  end


  def promote_errata from_env, to_env
    #repo->list of errata_ids
    errata_promote = { }

    not_included_errata.each do |err|
      product = err.product

      product.repos(from_env).each do |repo|
        if repo.is_cloned_in? to_env
          clone             = repo.get_clone to_env
          affecting_filters = (repo.filters + repo.product.filters).uniq

          if repo.has_erratum? err.errata_id and !clone.has_erratum? err.errata_id and
              !err.blocked_by_filters? affecting_filters
            errata_promote[clone] ||= []
            errata_promote[clone] << err.errata_id
          end
        end
      end
    end

    errata_promote.each_pair do |repo, errata|
      repo.add_errata(errata)
      Glue::Pulp::Errata.index_errata(errata)
    end
  end


  def promote_distributions from_env, to_env
    #repo->list of distribution_ids
    distribution_promote = { }

    for distro in self.distributions
      product = distro.product

      #skip distributions that have already been promoted with the products
      next if (products.uniq! or []).include? product

      product.repos(from_env).each do |repo|
        clone = repo.get_clone to_env
        next if clone.nil?

        if repo.has_distribution? distro.distribution_id and
            !clone.has_distribution? distro.distribution_id
          distribution_promote[clone] = distro.distribution_id
        end
      end
    end

    distribution_promote.each_pair do |repo, distro|
      repo.add_distribution(distro)
    end
  end

  def get_promotable_dependencies_for_packages package_names, from_repos, to_repos
    from_repo_ids     = from_repos.map { |r| r.pulp_id }
    @next_env_pkg_ids ||= package_ids(to_repos)

    resolved_deps = Resources::Pulp::Package.dep_solve(package_names, from_repo_ids)['resolved']
    resolved_deps = resolved_deps.values.flatten(1)
    resolved_deps = resolved_deps.reject { |dep| not @next_env_pkg_ids.index(dep['id']).nil? }
    resolved_deps
  end

  def repos_to_be_promoted
    repos = self.repos || []
    repos += self.system_templates.map { |tpl| tpl.repos_to_be_promoted }.flatten(1)
    return repos.uniq
  end

  def products_to_be_promoted
    products = self.products || []
    products += self.system_templates.map { |tpl| tpl.products_to_be_promoted }.flatten(1)
    return products.uniq
  end
  
  def calc_dependencies
    all_dependencies = []
    not_included_products.each do |product|
      dependencies     = calc_dependencies_for_product product
      all_dependencies += build_dependencies(product, dependencies)
    end
    all_dependencies
  end

  def calc_and_save_dependencies
    self.dependencies = self.calc_dependencies
    self.save()
  end

  def errata_for_dep_calc product
    cs_errata = ChangesetErratum.where({ :changeset_id => self.id, :product_id => product.id })
    cs_errata.collect do |err|
      Glue::Pulp::Errata.find(err.errata_id)
    end
  end


  def packages_for_dep_calc product
    packages = []

    cs_pacakges = ChangesetPackage.where({ :changeset_id => self.id, :product_id => product.id })
    packages    += cs_pacakges.collect do |pack|
      Glue::Pulp::Package.find(pack.package_id)
    end

    packages += errata_for_dep_calc(product).collect do |err|
      err.included_packages
    end.flatten(1)

    packages
  end


  def calc_dependencies_for_product product
    from_env = self.environment.prior
    to_env   = self.environment

    package_names = packages_for_dep_calc(product).map { |p| p.name }.uniq
    return { } if package_names.empty?

    from_repos = not_included_repos(product, from_env)
    to_repos   = product.repos(to_env)

    dependencies = calc_dependencies_for_packages package_names, from_repos, to_repos
    dependencies
  end

  def calc_dependencies_for_packages package_names, from_repos, to_repos
    all_deps   = []
    deps       = []
    to_resolve = package_names
    while not to_resolve.empty?
      all_deps += deps

      deps = get_promotable_dependencies_for_packages to_resolve, from_repos, to_repos
      deps = Katello::PackageUtils::filter_latest_packages_by_name deps

      to_resolve = deps.map { |d| d['provides'] }.flatten(1).uniq -
          all_deps.map { |d| d['provides'] }.flatten(1) -
          package_names
    end
    all_deps
  end

  def build_dependencies product, dependencies
    new_dependencies = []

    dependencies.each do |dep|
      new_dependencies << ChangesetDependency.new(:package_id    => dep['id'],
                                                  :display_name  => dep['filename'],
                                                  :product_id    => product.id,
                                                  :dependency_of => '???',
                                                  :changeset     => self)
    end
    new_dependencies
  end

  def generate_metadata from_env, to_env
    async_tasks = affected_repos.collect do |repo|
      repo.get_clone(to_env).generate_metadata
    end
    async_tasks
  end

  def affected_repos
    repos = []
    repos += self.packages.collect { |e| e.promotable_repositories }.flatten(1)
    repos += self.errata.collect { |p| p.promotable_repositories }.flatten(1)
    repos += self.distributions.collect { |d| d.promotable_repositories }.flatten(1)

    repos.uniq
  end

  def package_ids repos
    pkg_ids = []
    repos.each do |repo|
      pkg_ids += repo.packages.collect { |pkg| pkg.id }
    end
    pkg_ids
  end

  def repos_to_be_promoted
    repos = self.repos || []
    repos += self.system_templates.map { |tpl| tpl.repos_to_be_promoted }.flatten(1)
    return repos.uniq
  end

  def products_to_be_promoted
    products = self.products || []
    products += self.system_templates.map { |tpl| tpl.products_to_be_promoted }.flatten(1)
    return products.uniq
  end
end