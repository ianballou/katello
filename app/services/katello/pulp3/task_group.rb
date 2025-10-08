module Katello
  module Pulp3
    class TaskGroup
      WAITING = 'waiting'.freeze
      SKIPPED = 'skipped'.freeze
      RUNNING = 'running'.freeze
      COMPLETED = 'completed'.freeze
      CANCELLED = 'canceled'.freeze
      FAILED = 'failed'.freeze

      IN_PROGRESS_STATES = [WAITING, RUNNING].freeze

      #needed for serialization in dynflow
      delegate :to_hash, :to => :task_group_data
      delegate :dig, :to => :task_group_data

      attr_accessor :prn
      attr_reader :pulp_data

      # A call report Looks like:  {"task":"/pulp/api/v3/tasks/5/"}
      #{
      # "prn":"prn:pulp:task-group:d9841aaa-8a47-4e31-9018-10e4430766bf",
      #     "description":"Migration Sub-tasks",
      #     "waiting":0,
      #     "skipped":0,
      #     "running":0,
      #     "completed":0,
      #     "canceled":0,
      #     "failed":1
      # }

      def self.new_from_prn(smart_proxy, prn)
        group = self.new(smart_proxy, {'prn' => prn})
        group.clear_task_group_data
        group
      end

      def initialize(smart_proxy, data)
        @smart_proxy = smart_proxy
        @pulp_data = data.with_indifferent_access
        @prn = @pulp_data['prn']
        Rails.logger.error("Got empty prn on #{@pulp_data}") if @prn.nil?
      end

      def task_group_data
        @pulp_data ||= tasks_groups_api.read(@prn).as_json.with_indifferent_access
      end

      def tasks_groups_api
        ::Katello::Pulp3::Api::Core.new(@smart_proxy).task_groups_api
      end

      def tasks_api
        ::Katello::Pulp3::Api::Core.new(@smart_proxy).tasks_api
      end

      def done?
        IN_PROGRESS_STATES.all? { |state| task_group_data[state] == 0 }
      end

      def group_progress_reports
        task_group_data['group_progress_reports']
      end

      def poll
        clear_task_group_data
        task_group_data
      end

      def clear_task_group_data
        @pulp_data = nil
      end

      def started?
        [SKIPPED, RUNNING, COMPLETED, CANCELLED, FAILED].any? { |state| task_group_data[state] }
      end

      def error
        return if task_group_data[WAITING] > 0 || task_group_data[RUNNING] > 0
        if task_group_data[FAILED] > 0
          messages = query_task_group_errors(task_group_data)
          return "#{task_group_data[FAILED]} subtask(s) failed for task group #{@prn}.\nErrors:\n #{messages.join("\n")}"
        elsif task_group_data[CANCELLED] > 0
          "#{task_group_data[CANCELLED]} subtask(s) cancelled for task group #{@prn}."
        end
      end

      def query_task_group_errors(task_group_data)
        messages = []
        tasks_api = core_api.tasks_api
        tasks_response = core_api.class.fetch_from_list do |page_opts|
          tasks_api.list(page_opts.merge(task_group: task_group_data['prn'], state__in: [FAILED]))
        end
        tasks_response.collect do |result|
          messages << result.error
        end
        return messages
      end

      def core_api
        ::Katello::Pulp3::Api::Core.new(@smart_proxy)
      end

      def cancel
        tasks_api = core_api.tasks_api
        tasks_response = core_api.class.fetch_from_list do |page_opts|
          tasks_api.list(page_opts.merge(task_group: task_group_data['prn'], state__in: [RUNNING, WAITING]))
        end
        tasks_response.collect do |result|
          ::Katello::Pulp3::Api::Core.new(@smart_proxy).cancel_task(result.prn)
        end
      end
    end
  end
end
