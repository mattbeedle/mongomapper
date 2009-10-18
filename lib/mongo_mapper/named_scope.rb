module MongoMapper
  module NamedScope
    # All subclasses of ActiveRecord::Base have one named scope:
    # * <tt>scoped</tt> - which allows for the creation of anonymous \scopes, on the fly: <tt>Shirt.scoped(:conditions => {:color => 'red'}).scoped(:include => :washing_instructions)</tt>
    #
    # These anonymous \scopes tend to be useful when procedurally generating complex queries, where passing
    # intermediate values (scopes) around as first-class objects is convenient.
    #
    # You can define a scope that applies to all finders using ActiveRecord::Base.default_scope.
    def self.included(base)
      base.class_eval do
        extend ClassMethods
        named_scope :scoped, lambda { |scope| scope }
      end
    end

    module ClassMethods
      def scopes
        read_inheritable_attribute(:scopes) || write_inheritable_attribute(:scopes, {})
      end

      def current_scoped_methods
        scoped_methods.last
      end

      def scoped_methods
        Thread.current[:"#{self}_scoped_methods"] ||= self.default_scoping.dup
      end

      def default_scope(options={})
        self.default_scoping << { :find => options, :create => options[:conditions].is_a?(Hash) ? options[:conditions] : {} }
      end

      def default_scoping
        @default_scoping || []
      end

      # Adds a class method for retrieving and querying objects. A scope represents a narrowing of a database query,
      # such as <tt>:conditions => {:color => :red}, :select => 'shirts.*', :include => :washing_instructions</tt>.
      #
      #   class Shirt < ActiveRecord::Base
      #     named_scope :red, :conditions => {:color => 'red'}
      #     named_scope :dry_clean_only, :joins => :washing_instructions, :conditions => ['washing_instructions.dry_clean_only = ?', true]
      #   end
      # 
      # The above calls to <tt>named_scope</tt> define class methods Shirt.red and Shirt.dry_clean_only. Shirt.red, 
      # in effect, represents the query <tt>Shirt.find(:all, :conditions => {:color => 'red'})</tt>.
      #
      # Unlike <tt>Shirt.find(...)</tt>, however, the object returned by Shirt.red is not an Array; it resembles the association object
      # constructed by a <tt>has_many</tt> declaration. For instance, you can invoke <tt>Shirt.red.find(:first)</tt>, <tt>Shirt.red.count</tt>,
      # <tt>Shirt.red.find(:all, :conditions => {:size => 'small'})</tt>. Also, just
      # as with the association objects, named \scopes act like an Array, implementing Enumerable; <tt>Shirt.red.each(&block)</tt>,
      # <tt>Shirt.red.first</tt>, and <tt>Shirt.red.inject(memo, &block)</tt> all behave as if Shirt.red really was an Array.
      #
      # These named \scopes are composable. For instance, <tt>Shirt.red.dry_clean_only</tt> will produce all shirts that are both red and dry clean only.
      # Nested finds and calculations also work with these compositions: <tt>Shirt.red.dry_clean_only.count</tt> returns the number of garments
      # for which these criteria obtain. Similarly with <tt>Shirt.red.dry_clean_only.average(:thread_count)</tt>.
      #
      # All \scopes are available as class methods on the ActiveRecord::Base descendant upon which the \scopes were defined. But they are also available to
      # <tt>has_many</tt> associations. If,
      #
      #   class Person < ActiveRecord::Base
      #     has_many :shirts
      #   end
      #
      # then <tt>elton.shirts.red.dry_clean_only</tt> will return all of Elton's red, dry clean
      # only shirts.
      #
      # Named \scopes can also be procedural:
      #
      #   class Shirt < ActiveRecord::Base
      #     named_scope :colored, lambda { |color|
      #       { :conditions => { :color => color } }
      #     }
      #   end
      #
      # In this example, <tt>Shirt.colored('puce')</tt> finds all puce shirts.
      #
      # Named \scopes can also have extensions, just as with <tt>has_many</tt> declarations:
      #
      #   class Shirt < ActiveRecord::Base
      #     named_scope :red, :conditions => {:color => 'red'} do
      #       def dom_id
      #         'red_shirts'
      #       end
      #     end
      #   end
      #
      #
      # For testing complex named \scopes, you can examine the scoping options using the
      # <tt>proxy_options</tt> method on the proxy itself.
      #
      #   class Shirt < ActiveRecord::Base
      #     named_scope :colored, lambda { |color|
      #       { :conditions => { :color => color } }
      #     }
      #   end
      #
      #   expected_options = { :conditions => { :colored => 'red' } }
      #   assert_equal expected_options, Shirt.colored('red').proxy_options
      def named_scope(name, options = {}, &block)
        name = name.to_sym
        scopes[name] = lambda do |parent_scope, *args|
          Scope.new(parent_scope, case options
            when Hash
              options
            when Proc
              options.call(*args)
          end, &block)
        end
        (class << self; self end).instance_eval do
          define_method name do |*args|
            scopes[name].call(self, *args)
          end
        end
      end

      # Retrieve the scope for the given method and optional key.
      def scope(method, key = nil) #:nodoc:
        if current_scoped_methods && (scope = current_scoped_methods[method])
          key ? scope[key] : scope
        end
      end

      def set_readonly_option!(options) #:nodoc:
        # Inherit :readonly from finder scope if set.  Otherwise,
        # if :joins is not blank then :readonly defaults to true.
        unless options.has_key?(:readonly)
          if scoped_readonly = scope(:find, :readonly)
            options[:readonly] = scoped_readonly
          elsif !options[:joins].blank? && !options[:select]
            options[:readonly] = true
          end
        end
      end

      # Merges conditions so that the result is a valid +condition+
      def merge_conditions(*conditions)
        segments = []

        conditions.each do |condition|
          unless condition.blank?
            sql = sanitize_sql(condition)
            segments << sql unless sql.blank?
          end
        end

        "(#{segments.join(') AND (')})" unless segments.empty?
      end
      VALID_FIND_OPTIONS = [ :conditions, :include, :joins, :limit, :offset,
                             :order, :select, :readonly, :group, :having, :from, :lock ]

      def with_scope(method_scoping = {}, action = :merge, &block)
        method_scoping = method_scoping.method_scoping if method_scoping.respond_to?(:method_scoping)

        # Dup first and second level of hash (method and params).
        method_scoping = method_scoping.inject({}) do |hash, (method, params)|
          hash[method] = (params == true) ? params : params.dup
          hash
        end

        method_scoping.assert_valid_keys([ :find, :create ])

        if f = method_scoping[:find]
          f.assert_valid_keys(VALID_FIND_OPTIONS)
          set_readonly_option! f
        end

        # Merge scopings
        if [:merge, :reverse_merge].include?(action) && current_scoped_methods
          method_scoping = current_scoped_methods.inject(method_scoping) do |hash, (method, params)|
            case hash[method]
              when Hash
                if method == :find
                  (hash[method].keys + params.keys).uniq.each do |key|
                    merge = hash[method][key] && params[key] # merge if both scopes have the same key
                    if key == :conditions && merge
                      if params[key].is_a?(Hash) && hash[method][key].is_a?(Hash)
                        #hash[method][key] = merge_conditions(hash[method][key].deep_merge(params[key]))
                        hash[method][key] = hash[method][key].deep_merge(params[key])
                      else
                        hash[method][key] = merge_conditions(params[key], hash[method][key])
                      end
                    elsif key == :include && merge
                      hash[method][key] = merge_includes(hash[method][key], params[key]).uniq
                    elsif key == :joins && merge
                      hash[method][key] = merge_joins(params[key], hash[method][key])
                    else
                      hash[method][key] = hash[method][key] || params[key]
                    end
                  end
                else
                  if action == :reverse_merge
                    hash[method] = hash[method].merge(params)
                  else
                    hash[method] = params.merge(hash[method])
                  end
                end
              else
                hash[method] = params
            end
            hash
          end
        end

        self.scoped_methods << method_scoping
        begin
          yield
        ensure
          self.scoped_methods.pop
        end
      end
    end

    class Scope
      attr_reader :proxy_scope, :proxy_options, :current_scoped_methods_when_defined
      NON_DELEGATE_METHODS = %w(nil? send object_id class extend find size count sum average maximum minimum paginate first last empty? any? respond_to?).to_set
      [].methods.each do |m|
        unless m =~ /^__/ || NON_DELEGATE_METHODS.include?(m.to_s)
          delegate m, :to => :proxy_found
        end
      end

      delegate :scopes, :with_scope, :scoped_methods, :to => :proxy_scope

      def initialize(proxy_scope, options, &block)
        options ||= {}
        [options[:extend]].flatten.each { |extension| extend extension } if options[:extend]
        extend Module.new(&block) if block_given?
        unless Scope === proxy_scope
          @current_scoped_methods_when_defined = proxy_scope.send(:current_scoped_methods)
        end
        @proxy_scope, @proxy_options = proxy_scope, options.except(:extend)
      end

      def reload
        load_found; self
      end

      def first(*args)
        if args.first.kind_of?(Integer) || (@found && !args.first.kind_of?(Hash))
          proxy_found.first(*args)
        else
          find(:first, *args)
        end
      end

      def last(*args)
        if args.first.kind_of?(Integer) || (@found && !args.first.kind_of?(Hash))
          proxy_found.last(*args)
        else
          find(:last, *args)
        end
      end

      def size
        @found ? @found.length : count
      end

      def empty?
        @found ? @found.empty? : count.zero?
      end

      def respond_to?(method, include_private = false)
        super || @proxy_scope.respond_to?(method, include_private)
      end

      def any?
        if block_given?
          proxy_found.any? { |*block_args| yield(*block_args) }
        else
          !empty?
        end
      end

      protected
      def proxy_found
        @found || load_found
      end

      private
      def method_missing(method, *args, &block)
        if scopes.include?(method)
          scopes[method].call(self, *args)
        else
          with_scope({:find => proxy_options, :create => proxy_options[:conditions].is_a?(Hash) ?  proxy_options[:conditions] : {}}, :reverse_merge) do
            method = :new if method == :build
            if current_scoped_methods_when_defined && !scoped_methods.include?(current_scoped_methods_when_defined)
              with_scope current_scoped_methods_when_defined do
                proxy_scope.send(method, *args, &block)
              end
            else
              proxy_scope.send(method, *args, &block)
            end
          end
        end
      end

      def load_found
        @found = find(:all)
      end
    end
  end
end