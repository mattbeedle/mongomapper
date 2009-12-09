module MongoMapper
  module Validations    
    module Macros
      def validates_uniqueness_of(*args)
        add_validations(args, MongoMapper::Validations::ValidatesUniquenessOf)
      end
    end
    
    class ValidatesUniquenessOf < Validatable::ValidationBase
      option :scope, :case_sensitive
      default :case_sensitive => true

      def valid?(instance)
        value = instance[attribute]
        return true if allow_blank && value.blank?
        base_conditions = case_sensitive ? {self.attribute => value} : {}
        doc = instance.class.first(base_conditions.merge(scope_conditions(instance)).merge(where_conditions(instance)))
        doc.nil? || instance._id == doc._id
      end

      def message(instance)
        super || "has already been taken"
      end

      def scope_conditions(instance)
        return {} unless scope
        Array(scope).inject({}) do |conditions, key|
          conditions.merge(key => instance[key])
        end
      end

      def where_conditions(instance)
        conditions = {}
        unless case_sensitive
          conditions.merge!({'$where' => "this.#{attribute}.toLowerCase() == '#{instance[attribute].to_s.downcase}'"})
        end
        conditions
      end
    end
  end
end
