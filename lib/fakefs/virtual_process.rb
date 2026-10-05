# frozen_string_literal: true

module FakeFS
  # Explicit virtual process context for record locking, so fcntl lock
  # ownership can be exercised without depending on the real PID of the
  # process running the tests.
  class VirtualProcess
    DEFAULT_PID = 1

    @registry = {}
    @current_pid = DEFAULT_PID

    class << self
      # PID of the virtual process that new POSIX (F_SETLK) locks are
      # attributed to. Defaults to DEFAULT_PID, never to the real Process.pid.
      attr_accessor :current_pid

      def current
        self[current_pid]
      end

      def [](pid)
        @registry[pid] ||= new(pid)
      end

      # Runs the block as the virtual process +pid+, restoring the previous
      # context afterwards.
      def with(pid)
        previous = @current_pid
        @current_pid = pid
        yield self[pid]
      ensure
        @current_pid = previous
      end

      def reset!
        @registry = {}
        @current_pid = DEFAULT_PID
      end
    end

    attr_reader :pid

    def initialize(pid)
      @pid = pid
    end

    def inspect
      "#<#{self.class.name} pid=#{pid}>"
    end
  end
end
