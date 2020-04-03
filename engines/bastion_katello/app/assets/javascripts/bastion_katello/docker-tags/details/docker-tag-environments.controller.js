/**
 * @ngdoc object
 * @name  Bastion.docker-tags.controller:DockerTagDetailsController
 *
 * @requires $scope
 * @requires $location
 * @requires DockerTag
 * @requires CurrentOrganization
 *
 * @description
 *   Provides the functionality for the docker tags details environments list.
 */
angular.module('Bastion.docker-tags').controller('DockerTagEnvironmentsController',
    ['$scope', '$location', 'Nutupane', 'DockerTag', 'Repository', 'CurrentOrganization',
    function ($scope, $location, Nutupane, DockerTag, Repository, CurrentOrganization) {
        var params = {
            'organization_id': CurrentOrganization,
            'search': $location.search().search || "",
            'sort_by': 'name',
            'sort_order': 'ASC',
            'paged': false
        };

        var renderTable = function () {
            var newParams = {
                'organization_id': CurrentOrganization,
                'search': $location.search().search || "",
                'sort_by': 'name',
                'sort_order': 'ASC',
                'paged': false
            };
            var ids;
            var nutupane;
            if ($scope.tag.repositories.length > 1) {
                nutupane = new Nutupane(Repository, params, null, {disableAutoLoad: true});
                ids = _.map($scope.tag.repositories, 'id');
                newParams['skip_view_filter'] = true;
                newParams['docker_tag_id'] = $scope.tag.id;
            } else {
                nutupane = new Nutupane(DockerTag, params, null, {disableAutoLoad: true});
                ids = _.map($scope.tag.related_tags, 'id');
                newParams['ids[]'] = ids;
            }
            $scope.table = nutupane.table;
            nutupane.setParams(newParams);
            $scope.panel.loading = false;
            if (!_.isEmpty(ids)) {
                nutupane.refresh();
            }
        };

        $scope.controllerName = 'katello_docker_tags';

        if ($scope.tag) {
            $scope.panel.loading = false;
        }

        if ($scope.tag && $scope.tag.related_tags) {
            renderTable();
        } else {
            $scope.tag.$promise.then(renderTable);
        }
    }
]);
