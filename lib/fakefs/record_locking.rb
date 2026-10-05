# frozen_string_literal: true

module FakeFS
  # Simulates fcntl(2) byte-range record locks (struct flock) on fake files.
  #
  # Two ownership models are supported, mirroring Linux:
  #
  # * POSIX process locks (F_SETLK/F_SETLKW/F_GETLK) belong to the current
  #   FakeFS::VirtualProcess and are dropped when that process closes *any*
  #   descriptor for the file.
  # * Open file description locks (F_OFD_SETLK/F_OFD_SETLKW/F_OFD_GETLK)
  #   belong to the FakeFS::OpenFileDescription (shared by dup'ed
  #   descriptors, distinct across independent opens) and are dropped when
  #   its last descriptor is closed.
  #
  # Locks are stored per inode as a sorted list of non-overlapping Lock
  # segments; unlocking a sub-range may split a segment in two, and locking
  # an adjacent or overlapping range merges segments of the same owner.
  module RecordLocking
    # A single locked byte range. +last+ is exclusive; Float::INFINITY
    # means "to end of file" (l_len == 0 in struct flock).
    Lock = Struct.new(:owner, :type, :first, :last)

    # Lock owner: +kind+ is :process (POSIX locks) or :ofd (open file
    # description locks), +subject+ is a FakeFS::VirtualProcess or a
    # FakeFS::OpenFileDescription. Owners of different kinds never match,
    # so POSIX and OFD locks conflict with each other.
    Owner = Struct.new(:kind, :subject)

    # Raised by ControlledScheduler#drain when parked waiters can never
    # make progress.
    class DeadlockError < StandardError; end

    # Default scheduler: blocks the calling thread until the lock can be
    # acquired, woken whenever the lock table changes.
    class ThreadScheduler
      def initialize
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      def wait_for
        @mutex.synchronize do
          @condition.wait(@mutex) until yield
        end
        true
      end

      def signal
        @mutex.synchronize { @condition.broadcast }
      end
    end

    # Test scheduler: never sleeps. Blocking callers must run inside a
    # Fiber; they are parked in a queue and only advance when the test
    # explicitly calls #run_once or #drain.
    class ControlledScheduler
      attr_reader :waiters

      def initialize
        @waiters = []
      end

      def wait_for
        until yield
          @waiters << Fiber.current
          begin
            Fiber.yield
          rescue FiberError
            raise FiberError, 'ControlledScheduler waiters must run inside a Fiber'
          end
        end
        true
      end

      def signal; end

      # Resumes every parked waiter once; waiters that are still blocked
      # park themselves again. Returns the number of waiters whose fiber
      # completed.
      def run_once
        pending = @waiters
        @waiters = []
        finished = 0
        pending.each do |fiber|
          next unless fiber.alive?
          fiber.resume
          finished += 1 unless fiber.alive?
        end
        finished
      end

      # Resumes waiters until none are left. Raises DeadlockError if a full
      # round completes no waiter, i.e. the remaining ones can never
      # proceed with the locks currently held.
      def drain
        until @waiters.empty?
          if run_once.zero?
            raise DeadlockError, 'lock waiters cannot make progress'
          end
        end
        true
      end
    end

    class << self
      attr_writer :scheduler

      def scheduler
        @scheduler ||= ThreadScheduler.new
      end

      def reset!
        @scheduler = nil
      end

      def locks_for(inode)
        inode.record_locks
      end

      # Acquires a lock, or releases locks when +type+ is :unlock.
      # With wait: true, blocks (via the scheduler) until the lock can be
      # acquired. Returns true when the request was satisfied, false when
      # a non-blocking request conflicts with an existing lock.
      def lock(inode, owner, type, first, last, wait: false)
        if type == :unlock
          mutate(inode) { |locks| apply(locks, owner, :unlock, first, last) }
          return true
        end

        attempt = lambda do
          if conflicting_lock(inode, owner, type, first, last)
            false
          else
            mutate(inode) { |locks| apply(locks, owner, type, first, last) }
            true
          end
        end

        if wait
          scheduler.wait_for(&attempt)
        else
          attempt.call
        end
      end

      # The first lock (lowest start) owned by someone else that would
      # block a lock of +type+ on [first, last), or nil.
      def conflicting_lock(inode, owner, type, first, last)
        locks_for(inode).find do |lock|
          lock.owner != owner &&
            lock.first < last && first < lock.last &&
            (type == :write || lock.type == :write)
        end
      end

      # POSIX semantics: closing any descriptor for the file drops every
      # lock the process holds on that inode.
      def release_process_locks(inode, process)
        release_owned(inode, Owner.new(:process, process))
      end

      # OFD semantics: locks are dropped when the last descriptor of the
      # open file description is closed.
      def release_ofd_locks(inode, description)
        release_owned(inode, Owner.new(:ofd, description))
      end

      private

      def release_owned(inode, owner)
        mutate(inode) { |locks| locks.reject { |lock| lock.owner == owner } }
      end

      def mutate(inode)
        locks = yield locks_for(inode)
        inode.record_locks = locks.sort_by(&:first)
        scheduler.signal
        locks
      end

      # Removes the parts of +owner+'s locks covered by [first, last),
      # splitting ranges when partially covered, then inserts the new lock
      # (unless +type+ is :unlock), merging it with adjacent ranges of the
      # same owner and type.
      def apply(locks, owner, type, first, last)
        kept = []
        locks.each do |lock|
          if lock.owner == owner && lock.first < last && first < lock.last
            kept << Lock.new(owner, lock.type, lock.first, first) if lock.first < first
            kept << Lock.new(owner, lock.type, last, lock.last) if lock.last > last
          else
            kept << lock
          end
        end
        return kept if type == :unlock

        merged_first = first
        merged_last = last
        kept = kept.reject do |lock|
          next false unless lock.owner == owner && lock.type == type
          if lock.last == merged_first
            merged_first = lock.first
            true
          elsif lock.first == merged_last
            merged_last = lock.last
            true
          else
            false
          end
        end
        kept << Lock.new(owner, type, merged_first, merged_last)
        kept
      end
    end
  end
end
