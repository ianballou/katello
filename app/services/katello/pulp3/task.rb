module Katello
  module Pulp3
    class Task
      # A call report Looks like:  {"task":"/pulp/api/v3/tasks/5/"}
      # {
      #    "prn":"/pulp/api/v3/tasks/4/",
      #    "pulp_created":"2019-02-21T19:50:40.476767Z",
      #    "job_id":"d0359658-d926-47a2-b430-1b2092b3bd86",
      #    "state":"completed",
      #    "name":"pulp_file.app.tasks.publishing.publish",
      #    "started_at":"2019-02-21T19:50:40.556002Z",
      #    "finished_at":"2019-02-21T19:50:40.618397Z",
      #    "non_fatal_errors":[
      #
      #    ],
      #    "error":null,
      #    "worker":"/pulp/api/v3/workers/1/",
      #    "parent":null,
      #    "spawned_tasks":[
      #
      #    ],
      #    "progress_reports":[
      #
      #    ],
      #    "created_resources":[
      #       "/pulp/api/v3/publications/1/"
      #    ]
      # }

      WAITING = 'waiting'.freeze
      SKIPPED = 'skipped'.freeze
      RUNNING = 'running'.freeze
      COMPLETED = 'completed'.freeze
      FAILED = 'failed'.freeze
      CANCELED = 'canceled'.freeze

      FINISHED_STATES = [COMPLETED, FAILED, CANCELED, SKIPPED].freeze

      #needed for serialization in dynflow

      attr_reader :pulp_data

      delegate :[], :key?, :dig, :to_hash, :to => :task_data

      def initialize(smart_proxy, data)
        @smart_proxy = smart_proxy
        if (prn = data['task'])
          @prn = prn
        else
          @pulp_data = data.with_indifferent_access
          @prn = @pulp_data['prn']
          Rails.logger.error("Got empty prn on #{@pulp_data}") if @prn.nil?
        end
      end

      def self.version_prn(tasks)
        tasks = [tasks] unless tasks.is_a?(Array)
        version_prns = tasks.map { |task| task[:created_resources] }.flatten
        version_prns = version_prns.select { |prn| ::Katello::Pulp3::Repository.version_prn?(prn) }
        Rails.logger.debug("Got multiple version_prns for pulp task: #{tasks}") if version_prns.length > 2
        version_prns.last
      end

      def self.publication_prn(tasks)
        tasks = [tasks] unless tasks.is_a?(Array)
        publication_prns = tasks.map { |task| task[:created_resources] }.flatten
        publication_prns = publication_prns.select { |prn| ::Katello::Pulp3::Repository.publication_prn?(prn) }
        Rails.logger.debug("Got multiple publication prns for pulp task: #{tasks}") if publication_prns.length > 2
        publication_prns.last #return the last prn to workaround https://pulp.plan.io/issues/9098
      end

      def task_data(force_refresh = false)
        @pulp_data = nil if force_refresh
        @pulp_data ||= tasks_api.read(@prn).as_json.with_indifferent_access
      end

      delegate :tasks_api, to: :core_api

      def core_api
        ::Katello::Pulp3::Api::Core.new(@smart_proxy)
      end

      def task_group_prn
        task_data[:task_group] || task_data[:created_resources].find { |prn| prn.starts_with?("prn:pulp:task-group:") }
      end

      def done?
        task_data[:finished_at] || FINISHED_STATES.include?(task_data[:state])
      end

      def progress_reports
        task_data['progress_reports']
      end

      def correlation_id
        task_data['logging_cid']
      end

      def poll
        task_data(true)
        self
      end

      def started?
        task_data[:started_at]
      end

      def error
        case task_data[:state]
        when CANCELED
          _("Task canceled")
        when FAILED
          if task_data[:error][:description].blank?
            _("Pulp task error")
          else
            task_data[:error][:description]
          end
        end
      end

      def cancel
        core_api.cancel_task(task_data['prn'])
        #the main task may have completed, so cancel spawned tasks too
        task_data['spawned_tasks']&.each do |spawned|
          core_api.cancel_task(spawned['prn'])
        end
      end
    end
  end
end
