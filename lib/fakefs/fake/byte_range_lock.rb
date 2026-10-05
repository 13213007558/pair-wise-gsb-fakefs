# frozen_string_literal: true

module FakeFS
  # Byte-range lock request understood by File#fcntl. It has the same fields
  # as Ruby's platform File::Flock/Fcntl::Flock structs.
  ByteRangeLock = Struct.new(:l_type, :l_start, :l_len, :l_whence, :l_pid)

  # Stores POSIX and open-file-description byte-range locks for one inode.
  class ByteRangeLockTable
    StoredLock = Struct.new(
      :lock_type, :start_position, :byte_length, :owner, keyword_init: true
    )
    Request = Struct.new(
      :lock_type, :start_position, :byte_length, keyword_init: true
    )

    def initialize
      @locks = []
    end

    def get(request, owner)
      first_conflict(request, owner)
    end

    def set(request, owner, blocking)
      loop do
        conflicting_lock = first_conflict(request, owner)

        if conflicting_lock
          if blocking
            scheduler = LockScheduler.current
            raise RuntimeError, 'blocking fcntl requires a FakeFS::LockScheduler' unless scheduler

            scheduler.wait(self, request, owner)
            next
          end

          raise Errno::EAGAIN
        end

        replace(request, owner)
        return 0
      end
    end

    def unlock(start, byte_length, owner)
      finish = start + byte_length
      remaining = @locks.flat_map do |lock|
        next [lock] unless lock.owner == owner && overlaps?(lock, start, finish)

        pieces = []
        lock_finish = lock.start_position + lock.byte_length
        if lock.start_position < start
          pieces << StoredLock.new(
            lock_type: lock.lock_type,
            start_position: lock.start_position,
            byte_length: start - lock.start_position,
            owner: lock.owner
          )
        end

        next_length = lock_finish - finish
        if next_length.positive?
          pieces << StoredLock.new(
            lock_type: lock.lock_type,
            start_position: finish,
            byte_length: next_length,
            owner: lock.owner
          )
        end

        pieces
      end

      @locks = compact_locks(remaining)
      0
    end

    def release_owner(owner)
      @locks.reject! { |lock| lock.owner == owner }
      nil
    end

    def locks_for(owner)
      @locks.select { |lock| lock.owner == owner }.map do |lock|
        {
          type: lock.lock_type,
          start: lock.start_position,
          length: lock.byte_length
        }
      end
    end

    private

    def first_conflict(request, owner)
      request_finish = request.start_position + request.byte_length
      @locks.sort_by(&:start_position).find do |lock|
        lock.owner != owner &&
          overlaps?(lock, request.start_position, request_finish) &&
          (
            lock.lock_type == RealFcntl::F_WRLCK ||
            request.lock_type == RealFcntl::F_WRLCK
          )
      end
    end

    def replace(request, owner)
      request_finish = request.start_position + request.byte_length
      retained = @locks.reject do |lock|
        lock.owner == owner && overlaps?(lock, request.start_position, request_finish)
      end
      retained << StoredLock.new(
        lock_type: request.lock_type,
        start_position: request.start_position,
        byte_length: request.byte_length,
        owner: owner
      )
      @locks = compact_locks(retained)
    end

    def overlaps?(lock, start, finish)
      lock.start_position < finish && start < lock.start_position + lock.byte_length
    end

    def compact_locks(locks)
      locks.sort_by(&:start_position).each_with_object([]) do |lock, merged|
        previous = merged.last
        if previous &&
           previous.owner == lock.owner &&
           previous.lock_type == lock.lock_type &&
           previous.start_position + previous.byte_length == lock.start_position
          previous.byte_length += lock.byte_length
        else
          merged << lock
        end
      end
    end
  end
end
