# frozen_string_literal: true

require 'forwardable'
require 'json'
require 'pathname'
require 'active_support/inflector'
require 'oas_parser'

module OpenAPIClientGenerator

  class Endpoint
    class PositionalParameterizer
      def parameterize(args)
        args.empty? ? "options = {}" : "#{args.join(", ")}, options = {}"
      end
    end

    class KwargsParameterizer
      def parameterize(args)
        args.empty? ? "**options" : "#{args.map {|arg| arg + ":"}.join(", ")}, **options"
      end
    end

    extend Forwardable

    VERB_PRIORITY = %w(GET POST PUT PATCH DELETE)

    attr_reader :definition, :parameterizer
    def initialize(oas_endpoint, parameterizer: OpenAPIClientGenerator::Endpoint::PositionalParameterizer)
      @definition    = oas_endpoint
      @parameterizer = parameterizer.new
    end

    def to_s
      [
        tomdoc,
        method_definition,
        enum_definitions
      ].compact.join("\n")
    end

    def tomdoc
      <<-TOMDOC.chomp
      # #{method_summary}
      #
      # #{parameter_documentation.join("\n      # ")}
      # @return #{return_type_description} #{return_value_description}
      # @see #{definition.raw["externalDocs"]["url"]}
      TOMDOC
    end

    def method_summary
      org_summary = definition.summary.gsub("#{namespace}", "org #{namespace}").gsub("a org", "an org")
      org?? org_summary : definition.summary
    end

    def method_definition
      <<-DEF.chomp
      def #{method_name}(#{parameters})
        #{method_implementation}
      end
      DEF
    end

    def enum_definitions
      result = []
      if definition.request_body
        definition.request_body.properties_for_format("application/json").each do |param|
          if param.enum && param.enum.size < 3 && param.default.nil?
            param.enum.each do |enum|
              enum_action = enum.delete_suffix("d")
              parameter_docs = parameter_documentation.reject { |p| p.include? param.name }
              result << %Q(
     # #{enum_action.capitalize} an #{namespace}
     #
     # #{parameter_docs.join("\n     # ")}
     def #{enum_action}_#{namespace}(#{parameters})
        options[:#{param.name}] = "#{enum}"
        #{method_implementation}
      end)
            end
          end
        end
      end

      if result.any?
        result.join("\n")
      end
    end

    def singular?
      return true unless definition.responses.first.content.present?
      definition.responses.first.content["application/json"]["schema"]["type"] != "array"
    end

    def method_implementation
      [
        *option_overrides,
        api_call,
      ].reject(&:empty?).join("\n        ")
    end

    def option_overrides
      options = []
      if definition.request_body
        params = definition.request_body.properties_for_format("application/json").select do |param|
          param.required
        end.map do |param|
          normalization = ""
          if !!param.enum
            normalization = ".to_s.downcase"
          end
          options << "options[:#{param.name}] = #{param.name}#{normalization}"
          if param.raw["required"] && param.raw["required"] != true
            options << "raise Octokit::MissingKey.new unless #{param.name}.key? :#{param.raw["required"].first}"
          end
        end
      end
      if definition.raw["x-github"]["previews"].any? {|e| e["required"]}
        # this is a bit janky
        resource = definition.operation_id.split("/").first
        namespace_segments = namespace.split("_")
        preview_type = (resource == namespace_segments.last.pluralize) ? resource : namespace
        options << "opts = ensure_api_media_type(:#{preview_type}, options)"
      end
      options
    end

    def api_call
      option_format = definition.raw["x-github"]["previews"].any? {|e| e["required"]} ? "opts" : "options"
      if definition.raw["responses"].key? "204"
        "boolean_from_response :#{definition.method}, \"#{api_path}\", #{option_format}"
      elsif definition.parameters.any? {|p| p.name == "per_page"}
        "paginate \"#{api_path}\", #{option_format}"
      else
        "#{definition.method} \"#{api_path}\", #{option_format}"
      end
    end

    def api_path
      path = definition.path.path[1..-1]
      path = path.gsub("repos/{owner}/{repo}", "\#{Repository.path repo}")
      path = path.gsub("orgs/{org}", "\#{Organization.path org}")
      path = required_params.reduce(path) do |path, param|
        path.gsub("{#{param.name}}", "\#{#{param.name}}")
      end
    end

    def return_type_description
      if verb == "GET" && !singular?
        "[Array<Sawyer::Resource>]"
      elsif definition.raw["responses"].key? "204"
        "[Boolean]"
      else
        "[Sawyer::Resource]"
      end
    end

    def required_params
      params = definition.parameters.select(&:required).reject do |param|
        ["owner", "accept"].include?(param.name)
      end
      if definition.request_body
        params += definition.request_body.properties_for_format("application/json").select do |param|
          param.required
        end
      end
      params
    end

    def optional_params
      params = definition.parameters.reject(&:required).reject do |param|
        ["accept", "per_page", "page"].include?(param.name)
      end
      if definition.request_body
        params += definition.request_body.properties_for_format("application/json").reject do |param|
          param.required
        end
      end
      params
    end

    def parameter_type(param)
      {
        "repo" => "[Integer, String, Repository, Hash]",
        "org" => "[Integer, String]",
      }[param.name] || "[#{param.type.capitalize}]"
    end

    def parameter_description(param)
      return "A GitHub repository" if param.name == "repo"
      return "A GitHub organization" if param.name == "org"
      return "The ID of the #{param.name.gsub("_id", "").gsub("_", " ")}" if param.name.end_with? "_id"
      split_param =  param.name.split("_")
      split_description = param.description.split(" ")
      resource = split_param.size > 1 ? split_param.first : namespace.split("_").first
      return "The #{split_param.last} of the #{resource}" if split_description.last == "parameter"
      return collapse_lists(param).gsub("\n", "")
    end

    def collapse_lists(param)
      split_description = param.description.split("\\\*")
      test = param.description.split("\\\*")
      list = split_description.drop(1).map { |line| line.split("`")[1] }
      test2 = (split_description[0] + list.join(", "))
    end

    def parameter_documentation
      required_params.map {|param|
        "@param #{param.name} #{parameter_type(param)} #{parameter_description(param)}"
      } + optional_params.map {|param|
        "@option options [#{param.type.capitalize}] :#{param.name} #{parameter_description(param).gsub("\n", "")}"
      }
    end

    def return_value_description
      if verb == "GET"
        if namespace.include?("latest")
          "The #{namespace.gsub("_", " ")}"
        elsif !singular? or definition.parameters.any? {|p| p.name == "per_page"}
          "A list of #{namespace.gsub("_", " ")}"
        else singular?
          "A single #{namespace.gsub("_", " ")}"
        end
      elsif definition.raw["responses"].key? "204"
        "True on success, false otherwise"
      elsif verb == "POST"
        case namespace
        # Note: hardcoded check
        when "assignees"
          "The updated #{definition.tags.first.singularize}"
        else
          "The new #{namespace.gsub("_", " ").singularize}"
        end
      elsif verb == "PATCH"
        "The updated #{namespace.singularize.gsub("_", " ")}"
      else
        if definition.responses && definition.responses.first.content["application/json"]["schema"]["type"] == "array"
          "An array of the remaining #{namespace.pluralize}"
        else
          "The updated #{definition.operation_id.split("/").first.singularize}"
        end
      end
    end

    def verb
      definition.method.upcase
    end

    def parameters
      params = required_params.map do |p| 
        (p.raw["required"].present? && p.raw["required"] != true) ? "#{p.name} = {}" : p.name 
      end
      parameterizer.parameterize(params)
    end

    def namespace
      operation_array = definition.operation_id.split("/")
      namespace_array = operation_array.last.split("-")

      div_words = %w(for on about)
      if (div_words & namespace_array).any?
        words = namespace_array.select {|w| div_words.include? w}
        index = namespace_array.index(words.first)

        resource = namespace_array[index+1..-1].join("_").gsub("repo", "repository")
        return resource if words.first == "about"

        first_half = namespace_array[0..index-1]
        subresource = (first_half.size == 1) ? operation_array.first : first_half.drop(1).join("_")
        subresource = singular? ? subresource.singularize : subresource

        "#{resource}_#{subresource}"
      else
        operation_resource = singular? ? operation_array.first.singularize : operation_array.first
        (namespace_array.size == 1) ? operation_resource : namespace_array.drop(1).join("_")
      end
    end

    def action
      definition.operation_id.split("/").last.split("-").first
    end

    def org?
      definition.operation_id.split("/").first == "orgs"
    end

    def method_name
      method_name = case verb
        when "GET"
          namespace
        when "POST", "PATCH", "DELETE", "PUT"
          "#{action}_#{namespace}"
        else
        end
      org?? method_name.gsub(namespace, "org_#{namespace}") : method_name
    end

    def parts
      definition.path.path.split("/").reject { |segment| segment.include? "id" }
    end

    def resource_priority
      definition.tags.include?("repos")? 0 : 1
    end

    def priority
      [resource_priority, parts.count, VERB_PRIORITY.index(verb), singular?? 0 : 1]
    end
  end

  class API
    def self.at(definition, parameterizer: OpenAPIClientGenerator::Endpoint::PositionalParameterizer)
      grouped_paths = definition.paths.group_by do |oas_path|
        resource_for_path(oas_path.path)
      end
      grouped_paths.delete(:unsupported)
      grouped_paths.each do |resource, paths|
        endpoints = paths.each_with_object([]) do |path, arr|
          path.endpoints.each do |endpoint|
            arr << OpenAPIClientGenerator::Endpoint.new(endpoint, parameterizer: parameterizer)
          end
        end
        yield new(resource, endpoints: endpoints)
      end
    end

    def self.resource_for_path(path)
      path_segments = path.split("/").reject{ |segment| segment == "" }

      repo_resource = path_segments[3]
      org_resource = path_segments[2]
      primary_resource = path_segments[0]

      supported_resources = ["deployments","pages", "hooks", "releases", "labels", "milestones", "issues", "reactions"]
      resource = case path_segments.first
                 when "orgs"
                   org_resource
                 when "repos"
                   repo_resource
                 else
                   primary_resource
                 end
      return (supported_resources.include? resource) ? resource : :unsupported
    end

    attr_reader :resource, :endpoints
    def initialize(resource, endpoints: [])
      @resource = resource
      @endpoints = endpoints
    end

    def documentation_url
      endpoints.first.definition.raw["externalDocs"]["url"].gsub(/#.*/, "")
    end

    def to_s
      <<-FILE
module Octokit
  class Client
    # Methods for the #{resource.capitalize} API
    #
    # @see #{documentation_url}
    module #{resource.capitalize}

#{endpoints.sort_by(&:priority).join("\n\n")}
    end
  end
end
      FILE
    end
  end
end
