UpgradeTask.define_tasks(:katello) do
  [
    {:name => 'katello:correct_repositories', :long_running => true, :skip_failure => true, :always_run => true},
    {:name => 'katello:clean_backend_objects', :long_running => true, :skip_failure => true, :always_run => true},
    {:name => 'katello:upgrades:4.0:remove_ostree_puppet_content'},
    {:name => 'katello:upgrades:4.1:sync_noarch_content'},
    {:name => 'katello:upgrades:4.1:fix_invalid_pools'}
  ]
end
