# frozen_string_literal: true

module FakeFS
  # Deterministically advances fibers blocked in F_SETLKW byte-range locks.
  class LockScheduler
    Waiter = Struct.new(:fiber, keyword_init: true)

    STORAGE_KEY = :fakefs_lock_scheduler

    def self.current
      Fiber[STORAGE_KEY]
    end

    def initialize
      @waiters = []
    end

    def run(&block)
      previous_scheduler = Fiber[STORAGE_KEY]
      previous_process_id = ProcessContext.current_id
      fiber = Fiber.new do
        Fiber[STORAGE_KEY] = self
        Fiber[ProcessContext::STORAGE_KEY] = previous_process_id
        block.call
      ensure
        Fiber[STORAGE_KEY] = previous_scheduler
      end
      fiber.resume
      fiber
    end

    def waiting?
      !@waiters.empty?
    end

    def waiter_count
      @waiters.size
    end

    def advance
      waiter = @waiters.shift
      return false unless waiter

      waiter.fiber.resume
      true
    end

    def drain
      progressed = false
      progressed = true while advance
      progressed
    end

    def wait(_table, _request, _owner)
      waiter = Waiter.new(fiber: Fiber.current)
      @waiters << waiter
      Fiber.yield
    ensure
      @waiters.delete(waiter)
    end
  end
end
