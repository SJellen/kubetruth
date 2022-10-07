require_relative 'template'

module Kubetruth
  class Config

    include GemLogger::LoggerSupport

    class DuplicateSelection < Kubetruth::Error; end

    ProjectSpec = Struct.new(
      :scope,
      :name,
      :project_selector,
      :key_selector,
      :environment,
      :tag,
      :skip,
      :suppress_namespace_inheritance,
      :log_level,
      :included_projects,
      :context,
      :active_templates,
      :resource_templates,
      keyword_init: true
    ) do

      def initialize(*args, **kwargs)
        super(*args, **convert_types(kwargs))
      end

      def convert_types(hash)
        selector_key_pattern = /_selector$/
        hash.merge(hash) do |k, v|
          case k
            when selector_key_pattern
              Regexp.new(v)
            when /^resource_templates$/
              Hash[v.collect {|k, t| [k.to_s, Kubetruth::Template.new(t)] }]
            when /^context$/
              Kubetruth::Template::TemplateHashDrop.new(v)
            else
              v
          end
        end
      end

      def templates
        return resource_templates if active_templates.nil?
        resource_templates.select {|k, v| active_templates.include?(k) }
      end
  
      def to_s
        to_h.to_json
      end

      def inspect
        to_s
      end
    end

    DEFAULT_SPEC = {
      scope: 'override',
      name: '',
      project_selector: '',
      key_selector: '',
      environment: 'default',
      tag: nil,
      skip: false,
      suppress_namespace_inheritance: false,
      log_level: nil,
      included_projects: [],
      context: {},
      active_templates: nil,
      resource_templates: []
    }.freeze

    def initialize(project_mapping_crds)
      @project_mapping_crds = project_mapping_crds
      @spec_mapping = {}
    end

    def load
      @config ||= begin
        parts = @project_mapping_crds.group_by {|c| c[:scope] }
        raise ArgumentError.new("Multiple root ProjectMappings") if parts["root"] && parts["root"].size > 1

        root_mapping = parts["root"]&.first || {}
        overrides = parts["override"] || []

        config = DEFAULT_SPEC.merge(root_mapping)
        @root_spec = ProjectSpec.new(**config)
        logger.debug { "ProjectSpec for root mapping: #{@root_spec}"}
        @override_specs = overrides.collect do |o|
          spec = ProjectSpec.new(**config.deep_merge(o))
          logger.debug { "ProjectSpec for override mapping: #{spec}"}
          spec
        end
        config
      end
    end

    def root_spec
      load
      @root_spec
    end

    def override_specs
      load
      @override_specs
    end

    def spec_for_project(project_name)
      spec = @spec_mapping[project_name]
      return spec unless spec.nil?

      specs = override_specs.find_all { |o| project_name =~ o.project_selector }
      case specs.size
        when 0
          spec = root_spec
          logger.debug {"Using root spec for project '#{project_name}'"}
        when 1
          spec = specs.first
          logger.debug {"Using override spec '#{spec.name}:#{spec.project_selector.source}' for project '#{project_name}'"}
        else
          dupes = specs.collect {|s| "'#{s.name}:#{s.project_selector.source}'" }
          raise DuplicateSelection, "Multiple configuration specs (#{dupes.inspect}) match the project '#{project_name}': }"
      end

      @spec_mapping[project_name] = spec
      return spec
    end

  end
end
