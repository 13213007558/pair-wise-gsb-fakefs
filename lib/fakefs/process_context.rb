# frozen_string_literal: true

module FakeFS
  # Explicit virtual process identity used by POSIX byte-range locks.
  module ProcessContext
    STORAGE_KEY = :fakefs_process_id

    class << self
      def current_id
        Fiber[STORAGE_KEY] || 0
      end

      def current_id=(process_id)
        Fiber[STORAGE_KEY] = coerce_process_id(process_id)
      end

      def with(process_id)
        previous_id = current_id
        self.current_id = process_id
        yield
      ensure
        Fiber[STORAGE_KEY] = previous_id
      end

      private

      def coerce_process_id(process_id)
        unless process_id.is_a?(Integer)
          unless process_id.respond_to?(:to_int)
            raise TypeError, "no implicit conversion of #{process_id.class} into Integer"
          end
          process_id = process_id.to_int
        end

        unless process_id.is_a?(Integer)
          raise TypeError, "can't convert process id to Integer"
        end
        raise ArgumentError, 'process id must be non-negative' if process_id.negative?

        process_id
      end
    end
  end
end
