# frozen_string_literal: true

require "graphql"
require "graphql/client/collocated_enforcement"
require "graphql/client/schema/object_type"
require "graphql/client/schema/possible_types"
require "set"

module GraphQL
  class Client
    # Definitions are constructed by Client.parse and wrap a parsed AST of the
    # query string as well as hold references to any external query definition
    # dependencies.
    #
    # Definitions MUST be assigned to a constant.
    class Definition < Module
      def self.for(ast_node:, **kargs)
        case ast_node
        when Language::Nodes::OperationDefinition
          OperationDefinition.new(ast_node: ast_node, **kargs)
        when Language::Nodes::FragmentDefinition
          FragmentDefinition.new(ast_node: ast_node, **kargs)
        else
          raise TypeError, "expected node to be a definition type, but was #{ast_node.class}"
        end
      end

      def initialize(client:, document:, source_document:, ast_node:, source_location:)
        @client = client
        @document = document
        @source_document = source_document
        @definition_node = ast_node
        @source_location = source_location

        definition_type = case ast_node
        when GraphQL::Language::Nodes::OperationDefinition
          case ast_node.operation_type
          when "mutation"
            @client.schema.mutation
          when "subscription"
            @client.schema.subscription
          when "query", nil
            @client.schema.query
          else
            raise "Unexpected operation_type: #{ast_node.operation_type}"
          end
        when GraphQL::Language::Nodes::FragmentDefinition
          @client.get_type(ast_node.type.name)
        else
          raise "Unexpected ast_node: #{ast_node}"
        end

        @schema_class = client.types.define_class(self, [ast_node], definition_type)

        # Clear cache only needed during initialization
        @indexes = nil
      end

      # Internal: Get associated owner GraphQL::Client instance.
      attr_reader :client

      # Internal root schema class for definition. Returns
      # GraphQL::Client::Schema::ObjectType or
      # GraphQL::Client::Schema::PossibleTypes.
      attr_reader :schema_class

      # Internal: Get underlying operation or fragment definition AST node for
      # definition.
      #
      # Returns OperationDefinition or FragmentDefinition object.
      attr_reader :definition_node

      # Internal: Get original document that created this definition, without
      # any additional dependencies.
      #
      # Returns GraphQL::Language::Nodes::Document.
      attr_reader :source_document

      # Public: Global name of definition in client document.
      #
      # Returns a GraphQL safe name of the Ruby constant String.
      #
      #   "Users::UserQuery" #=> "Users__UserQuery"
      #
      # Returns String.
      def definition_name
        return @definition_name if defined?(@definition_name)

        if name
          @definition_name = name.gsub("::", "__").freeze
        else
          "#{self.class.name}_#{object_id}".gsub("::", "__").freeze
        end
      end

      # Public: Get document with only the definitions needed to perform this
      # operation.
      #
      # Returns GraphQL::Language::Nodes::Document with one OperationDefinition
      # and any FragmentDefinition dependencies.
      attr_reader :document

      # Public: Returns the Ruby source filename and line number containing this
      # definition was not defined in Ruby.
      #
      # Returns Array pair of [String, Fixnum].
      attr_reader :source_location

      def new(obj, errors = Errors.new)
        case schema_class
        when GraphQL::Client::Schema::PossibleTypes
          case obj
          when NilClass
            obj
          else
            cast_object(obj)
          end
        when GraphQL::Client::Schema::ObjectType::WithDefinition
          case obj
          when schema_class.klass
            if obj._definer == schema_class
              obj
            else
              cast_object(obj)
            end
          when nil
            nil
          when Hash
            schema_class.new(obj, errors)
          else
            cast_object(obj)
          end
        when GraphQL::Client::Schema::ObjectType
          case obj
          when nil, schema_class
            obj
          when Hash
            schema_class.new(obj, errors)
          else
            cast_object(obj)
          end
        else
          raise TypeError, "unexpected #{schema_class}"
        end
      end

      # Internal: Nodes AST indexes.
      def indexes
        @indexes ||= begin
          visitor = DefinitionVisitor.new(document)
          visitor.visit
          { definitions: visitor.definitions, spreads: visitor.spreads }
        end
      end

      class DefinitionVisitor < GraphQL::Language::Visitor
        attr_reader :spreads, :definitions

        def initialize(doc)
          super
          @spreads = {}
          @definitions = {}
          @current_definition = nil
        end

        def on_field(node, parent)
          @definitions[node] = @current_definition
          @spreads[node] = get_spreads(node)
          super
        end

        def on_fragment_definition(node, parent)
          @current_definition = node
          @definitions[node] = @current_definition
          @spreads[node] = get_spreads(node)
          super
        ensure
          @current_definition = nil
        end

        def on_operation_definition(node, parent)
          @current_definition = node
          @definitions[node] = @current_definition
          @spreads[node] = get_spreads(node)
          super
        ensure
          @current_definition = nil
        end

        def on_inline_fragment(node, parent)
          @definitions[node] = @current_definition
          super
        end

        private

        EMPTY_SET = Set.new.freeze

        def get_spreads(node)
          node_spreads = flatten_spreads(node).map(&:name)
          node_spreads.empty? ? EMPTY_SET : Set.new(node_spreads).freeze
        end

        def flatten_spreads(node)
          spreads = []
          node.selections.each do |selection|
            case selection
            when Language::Nodes::FragmentSpread
              spreads << selection
            when Language::Nodes::InlineFragment
              spreads.concat(flatten_spreads(selection))
            else
              # Do nothing, not a spread
            end
          end
          spreads
        end
      end

      private

        def cast_object(obj)
          if obj.class.is_a?(GraphQL::Client::Schema::ObjectType)
            unless obj._spreads.include?(definition_node.name)
              raise TypeError, "#{definition_node.name} is not included in #{obj.source_definition.name}"
            end
            schema_class.cast(obj.to_h, obj.errors)
          else
            raise TypeError, "unexpected #{obj.class}"
          end
        end
    end
  end
end
