require 'cache_back/conditions_parser'

module CacheBack
  module ReadMixin

    def self.extended(model_class)
      class << model_class
        alias_method_chain :find_some, :cache_back unless methods.include?('find_some_without_cache_back')
        alias_method_chain :find_every, :cache_back unless methods.include?('find_every_without_cache_back')
      end
    end

    def without_cache_back(&block)
      old_value = @use_cache_back || true
      @use_cache_back = false
      yield
    ensure
      @use_cache_back = old_value
    end

    def find_every_with_cache_back(options)
      attribute_value_pairs = cache_back_conditions_parser.attribute_value_pairs(options) if cache_safe?(options)

      limit = (options[:limit] || (scope(:find) || {})[:limit])

      if (limit.nil? || limit == 1) && attribute_value_pairs && has_cache_back_index_on?(attribute_value_pairs.map(&:first))
        collection_key = cache_back_key_for(attribute_value_pairs)
        collection_key << '/first' if limit == 1
        unless records = CacheBack.cache.read(collection_key)
          records = without_cache_back do
            find_every_without_cache_back(options)
          end

          if records.size == 1
            CacheBack.cache.write(collection_key, records[0])
          elsif records.size <= CacheBack::CONFIGURATION[:max_collection_size]
            records.each { |record| record.store_in_cache_back if record }
            CacheBack.cache.write(collection_key, records.map(&:cache_back_key))
          end
        end

        Array(records)
      else
        without_cache_back do
          find_every_without_cache_back(options)
        end
      end
    end

    def find_some_with_cache_back(ids, options)
      attribute_value_pairs = cache_back_conditions_parser.attribute_value_pairs(options) if cache_safe?(options)
      attribute_value_pairs << [:id, ids] if attribute_value_pairs

      limit = (options[:limit] || (scope(:find) || {})[:limit])

      if limit.nil? && attribute_value_pairs && has_cache_back_index_on?(attribute_value_pairs.map(&:first))
        id_to_key_map = Hash[ids.uniq.map { |id| [id, cache_back_key_for_id(id)] }]
        cached_record_map = CacheBack.cache.get_multi(id_to_key_map.values)

        missing_keys = Hash[cached_record_map.select { |key, record| record.nil? }].keys

        return cached_record_map.values if missing_keys.empty?

        missing_ids = Hash[id_to_key_map.invert.select { |key, id| missing_keys.include?(key) }].values

        db_records = without_cache_back do
          find_some_without_cache_back(missing_ids, options)
        end
        db_records.each { |record| record.store_in_cache_back if record }

        (cached_record_map.values + db_records).compact.uniq.sort { |x, y| x.id <=> y.id}
      else
        without_cache_back do
          find_some_without_cache_back(ids, options)
        end
      end
    end

    private

      def cache_safe?(options)
        @use_cache_back != false && [options, scope(:find) || {}].all? do |hash|
          result = hash[:select].nil? && hash[:joins].nil? && hash[:order].nil? && hash[:offset].nil?
          result && (options[:limit].nil? || options[:limit] == 1)
        end
      end

      def cache_back_conditions_parser
        @cache_back_conditions_parser ||= CacheBack::ConditionsParser.new(self)
      end
  end
end
