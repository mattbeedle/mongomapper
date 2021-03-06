# encoding: UTF-8
module MongoMapper
  module Plugins
    module Associations
      class ManyDocumentsProxy < Collection
        include MongoMapper::Plugins::DynamicQuerying::ClassMethods

        def find(*args)
          options = args.extract_options!
          klass.find(*args << scoped_options(options))
        end

        def find!(*args)
          options = args.extract_options!
          klass.find!(*args << scoped_options(options))
        end

        def paginate(options)
          klass.paginate(scoped_options(options))
        end

        def all(options={})
          klass.scoped(:conditions => scoped_options(options))
        end

        def first(options={})
          klass.first(scoped_options(options))
        end

        def last(options={})
          klass.last(scoped_options(options))
        end

        def count(options={})
          klass.count(scoped_options(options))
        end

        def replace(docs)
          load_target
          target.map(&:destroy)
          docs.each { |doc| prepare(doc).save }
          reset
        end

        def <<(*docs)
          ensure_owner_saved
          flatten_deeper(docs).each { |doc| prepare(doc).save }
          reset
        end
        alias_method :push, :<<
        alias_method :concat, :<<

        def build(attrs={})
          doc = klass.new(attrs)
          apply_scope(doc)
          @target ||= [] unless loaded?
          @target << doc
          doc
        end

        def create(attrs={})
          doc = klass.new(attrs)
          apply_scope(doc).save
          reset
          doc
        end

        def create!(attrs={})
          doc = klass.new(attrs)
          apply_scope(doc).save!
          reset
          doc
        end

        def destroy_all(options={})
          all(options).map(&:destroy)
          reset
        end

        def delete_all(options={})
          klass.delete_all(options.merge(scoped_conditions))
          reset
        end

        def nullify
          all.each do |doc|
            doc.update_attributes(self.foreign_key => nil)
          end
          reset
        end

        def save_to_collection(options={})
          @target.each { |doc| doc.save(options) } if @target
        end

        protected
          def scoped_conditions
            {self.foreign_key => proxy_owner.id}
          end

          def scoped_options(options)
            association.query_options.merge(options).merge(scoped_conditions)
          end

          def find_target
            all
          end

          def ensure_owner_saved
            proxy_owner.save if proxy_owner.new?
          end

          def prepare(doc)
            klass === doc ? apply_scope(doc) : build(doc)
          end

          def apply_scope(doc)
            ensure_owner_saved
            doc[foreign_key] = proxy_owner.id
            doc
          end

          def foreign_key
            options[:foreign_key] || proxy_owner.class.name.to_s.underscore.gsub("/", "_") + "_id"
          end
      end
    end
  end
end
